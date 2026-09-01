import Darwin
import Dispatch
import Synchronization
import Testing

@testable import CortaTerminal

/// M1.2 — `TIOCSWINSZ`, and child-exit reporting.
@Suite("PTY window size and child lifecycle")
struct PTYWindowSizeTests {
    @Test("the child sees the window size it was spawned with")
    func childSeesTheInitialWindowSize() throws {
        let pty = try PTY.spawn(
            executable: "/bin/stty",
            arguments: ["size"],
            size: TerminalSize(rows: 24, columns: 80)
        )
        defer { pty.close() }

        // `stty size` prints "rows columns".
        let output = pty.readOutput(containing: "24")
        #expect(fields(of: output) == ["24", "80"])
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("resizing is visible to the child")
    func resizeIsVisibleToTheChild() throws {
        // The child blocks on `read` until we let it through, so the resize
        // is guaranteed to precede `stty`.
        let pty = try PTYFixture.shell(
            "read -r _; stty size",
            size: TerminalSize(rows: 24, columns: 80)
        )
        defer { pty.close() }

        try pty.resize(to: TerminalSize(rows: 40, columns: 100))
        try pty.write(text: "\n")

        let output = pty.readOutput(containing: "40")
        #expect(output.contains("40 100"))
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("the pty reports the size it was set to")
    func ptyReportsItsOwnSize() throws {
        let size = TerminalSize(rows: 30, columns: 120, pixelWidth: 960, pixelHeight: 630)
        let pty = try PTYFixture.shell("read -r _", size: size)
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }

        #expect(try pty.size() == size)
        try pty.resize(to: TerminalSize(rows: 10, columns: 20))
        #expect(try pty.size() == TerminalSize(rows: 10, columns: 20))
    }

    @Test("a resized child receives SIGWINCH")
    func resizeRaisesSIGWINCHInTheChild() throws {
        let pty = try PTYFixture.shell(
            "trap 'stty size; exit 0' WINCH; echo READY; while :; do sleep 0.05; done",
            size: TerminalSize(rows: 24, columns: 80)
        )
        defer { pty.close() }

        _ = pty.readOutput(containing: "READY")
        try pty.resize(to: TerminalSize(rows: 50, columns: 132))

        let output = pty.readOutput(containing: "50")
        #expect(output.contains("50 132"))
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("the exit code of the child is reported")
    func reportsChildExitCode() throws {
        let notified = DispatchSemaphore(value: 0)
        let reported = Mutex<ChildExit?>(nil)
        let pty = try PTYFixture.shell("exit 7") { exit in
            reported.withLock { $0 = exit }
            notified.signal()
        }
        defer { pty.close() }

        #expect(pty.waitForExit() == .exited(code: 7))
        #expect(notified.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(reported.withLock { $0 } == .exited(code: 7))
        #expect(pty.exitStatus == .exited(code: 7))
    }

    @Test("a child killed by a signal is reported as signalled")
    func reportsTerminationBySignal() throws {
        let pty = try PTYFixture.shell("kill -TERM $$; sleep 5")
        defer { pty.close() }

        #expect(pty.waitForExit() == .signalled(signal: SIGTERM))
        #expect(pty.exitStatus?.isCleanExit == false)
    }

    @Test("terminate hangs up the whole process group")
    func terminateHangsUpTheProcessGroup() throws {
        // `sleep` is a grandchild: signalling only the direct child would
        // leak it (`SECURITY.md` §4.4).
        let pty = try PTYFixture.shell("echo READY; sleep 30")
        defer { pty.close() }

        _ = pty.readOutput(containing: "READY")
        #expect(pty.terminate())
        #expect(pty.waitForExit() == .signalled(signal: SIGHUP))
    }

    @Test("waiting for an already-reaped child returns the stored status")
    func waitingTwiceReturnsTheSameStatus() throws {
        let pty = try PTYFixture.shell("exit 3")
        defer { pty.close() }

        #expect(pty.waitForExit() == .exited(code: 3))
        #expect(pty.waitForExit() == .exited(code: 3))
    }
}
