import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

// `.serialized`: every test here spawns a real child process, and spawning
// in a heavily multithreaded process carries a real, if small, per-call
// risk (see `Spawn.swift`'s header comment) that scales with how many
// threads are doing how much concurrently. Running this suite's own
// spawns one at a time removes this suite's contribution to that risk
// during a parallel test run; it does not eliminate the underlying hazard.
//
// These tests spawn real children and share a machine with other spawns,
// so they wait on conditions, never on the clock: no fixed `Thread.sleep`
// before an assertion. Every wait polls the grid for the expected content;
// the only deadlines are 30-second ceilings that stop a wedged child from
// hanging the run — generous enough that reaching one means something is
// genuinely wrong, not that the machine was busy (CI is loaded too).
@Suite(.serialized) struct TerminalSessionTests {
    @Test func readsChildOutputIntoTheGrid() throws {
        let session = try TerminalSession(executable: "/bin/echo", arguments: ["hello"])
        defer { session.stop() }

        let text = waitForGrid(session) { $0.contains("hello") }
        #expect(
            text.contains("hello"),
            "expected the grid to contain the child's output; grid held:\n\(text)")
    }

    @Test func floodDoesNotHangTheReaderLoop() throws {
        // `yes` floods output; the reader thread must keep draining it
        // without the batch cap ever hanging (`PERFORMANCE.md` §2.1).
        let session = try TerminalSession(executable: "/usr/bin/yes")
        defer { session.stop() }

        let text = waitForGrid(session) { $0.contains("y") }
        #expect(
            text.contains("y"),
            "expected flood output in the grid; grid held:\n\(text)")
    }

    @Test func catOfALargeFileDoesNotStallTheChild() throws {
        // M1.19's other done-when: `cat` of a 100 MB file must not stall —
        // the reader thread has to keep draining even though the scrollback
        // (10,000 lines by default) evicts almost everything it reads.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-cat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: path) }

        let line = String(repeating: "x", count: 199) + "\n"
        let lineBytes = Array(line.utf8)
        let targetBytes = 100 * 1024 * 1024
        let lineCount = targetBytes / lineBytes.count
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        for _ in 0..<lineCount { handle.write(Data(lineBytes)) }
        try handle.close()

        let session = try TerminalSession(executable: "/bin/cat", arguments: [path.path])
        defer { session.stop() }

        let exit = session.pty.waitForExit(timeout: .seconds(30))
        #expect(exit != nil, "cat of a 100 MB file should finish well within 30s if the reader never stalls it")
    }

    @Test func controlCStopsAFloodingChild() throws {
        // The other half of M1.19's `yes` scenario: even while the reader
        // thread is draining a flood as fast as it can, writing ETX must
        // still reach the pty's line discipline and signal the child — the
        // write path is never blocked behind the read path.
        let session = try TerminalSession(executable: "/usr/bin/yes")
        defer { session.stop() }

        // Establish the precondition by condition, not by the clock: the
        // flood is visible in the grid before ETX is sent, so this test
        // exercises "^C reaches a *running* flood" on machines of any speed.
        let flooded = waitForGrid(session) { $0.contains("y") }
        #expect(
            flooded.contains("y"),
            "precondition: the child should be flooding before ^C is sent; grid held:\n\(flooded)")
        session.write([0x03])

        let exit = session.pty.waitForExit(timeout: .seconds(30))
        #expect(exit != nil, "^C should terminate a flooding child well within 30s")
    }

    @Test func writeDeliversBytesToTheChild() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        session.write(Array("hi\n".utf8))

        let text = waitForGrid(session) { $0.contains("hi") }
        #expect(
            text.contains("hi"),
            "expected the grid to echo the written bytes; grid held:\n\(text)")
    }

    /// M4.2: the grid-side reflow runs off the calling thread (measured too
    /// slow, at 100k lines, to run synchronously without stalling whoever
    /// called `resize` — see `TerminalSession.resize`'s doc comment) and
    /// signals completion through `onOutput`, the same hook a parse batch
    /// uses to wake a display link.
    @Test func resizeAppliesAsynchronouslyAndSignalsOnOutput() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        defer { session.stop() }

        let signaled = Mutex(false)
        session.onOutput = { signaled.withLock { $0 = true } }

        session.resize(to: TerminalSize(rows: 30, columns: 100))

        let deadline = ContinuousClock.now + .seconds(10)
        while session.snapshot().columns != 100, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(session.snapshot().rows == 30)
        #expect(session.snapshot().columns == 100)
        #expect(signaled.withLock { $0 })
    }

    /// Polls the grid until `condition` accepts its dump, or the hang
    /// ceiling expires — see the suite header. Returns the last dump either
    /// way, so a failing expectation can show what the grid actually held.
    private func waitForGrid(
        _ session: TerminalSession, timeout: Duration = .seconds(30),
        until condition: (String) -> Bool
    ) -> String {
        let deadline = ContinuousClock.now + timeout
        var dump = session.snapshot().dump()
        while !condition(dump), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            dump = session.snapshot().dump()
        }
        return dump
    }
}
