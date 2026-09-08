import Darwin
import Dispatch
import Foundation
import Testing

@testable import CortaTerminal

/// S08 — PTY lifecycle audit: close ordering, descriptor reuse, repeated
/// open/close, leak-free failure paths, and foreground/background tracking.
///
/// The reuse tests matter because the kernel recycles descriptor numbers:
/// the instant `PTY.close()` runs, `pty.fileDescriptor` is free for an
/// unrelated `open` to claim. Any operation that still used the stored
/// number afterwards would silently hit a stranger's file — so after close
/// every operation must fail with `.closed`, and a second close must not
/// close again.
///
/// `.serialized`: every test here spawns real children — see the
/// `.serialized` note on `TerminalSessionTests`.
@Suite("PTY lifecycle (S08)", .serialized)
struct PTYLifecycleTests {
    // MARK: Descriptor reuse after close

    @Test("a write after close cannot leak into a recycled descriptor")
    func writeAfterCloseDoesNotTouchARecycledDescriptor() throws {
        try withRecycledDescriptor { pty, file in
            #expect(throws: PTYError.closed) { try pty.write(text: "corta-miswrite") }
            #expect(
                file.byteCount == 0,
                "a write issued after close reached the descriptor's new owner")
        }
    }

    @Test("read, resize and size after close report .closed")
    func operationsAfterCloseThrowClosed() throws {
        let pty = try PTYFixture.shell("read -r _")
        defer {
            // The child is still blocked on input; hang it up by hand since
            // close happened mid-test.
            pty.terminate()
            _ = pty.waitForExit()
        }
        pty.close()

        #expect(throws: PTYError.closed) {
            var buffer = [UInt8](repeating: 0, count: 16)
            return try buffer.withUnsafeMutableBytes { try pty.read(into: $0) }
        }
        #expect(throws: PTYError.closed) { try pty.resize(to: TerminalSize()) }
        #expect(throws: PTYError.closed) { try pty.size() }
    }

    @Test("a second close does not close a recycled descriptor")
    func repeatedCloseDoesNotCloseARecycledDescriptor() throws {
        try withRecycledDescriptor { pty, file in
            pty.close()
            #expect(
                fcntl(file.descriptor, F_GETFD) != -1,
                "the second close closed a descriptor the pty no longer owns")
        }
    }

    @Test("concurrent closes run the underlying close exactly once")
    func concurrentCloseIsIdempotent() throws {
        try withRecycledDescriptor(concurrentClose: true) { pty, file in
            pty.close()
            #expect(fcntl(file.descriptor, F_GETFD) != -1)
        }
    }

    @Test("a closed pty reports no foreground job")
    func closedPTYReportsNoForegroundJob() throws {
        let pty = try PTYFixture.shell("sleep 30")
        defer {
            pty.terminate()
            _ = pty.waitForExit()
        }
        pty.close()

        #expect(pty.foregroundProcessGroup == nil)
        #expect(pty.hasForegroundJob == false)
        #expect(pty.foregroundProcessName == nil)
    }

    // MARK: Close and reap ordering

    @Test("closing the primary still lets the child be reaped")
    func closeDoesNotBreakReaping() throws {
        let pty = try PTYFixture.shell("sleep 30")
        // No terminate(): the kernel hangs up the session when the primary
        // goes away, and `waitForExit` must observe that on its own.
        pty.close()
        #expect(pty.waitForExit(timeout: .seconds(15)) != nil)
        pty.close()
    }

    @Test("terminate after the child exited signals nothing")
    func terminateAfterExitIsANoOp() throws {
        let pty = try PTYFixture.shell("exit 0")
        defer { pty.close() }

        #expect(pty.waitForExit() == .exited(code: 0))
        // The group is gone once the child is reaped; the id is free for the
        // kernel to recycle, so signalling it must not be attempted.
        #expect(pty.terminate() == false)
        #expect(pty.signalProcessGroup(SIGTERM) == false)
    }

    // MARK: Repeated open/close stability

    @Test("repeated spawn and close leaks no descriptors")
    func repeatedSpawnAndCloseLeaksNoDescriptors() throws {
        for _ in 0..<3 {
            let warmup = try PTY.spawn(executable: "/usr/bin/true")
            _ = warmup.waitForExit()
            warmup.close()
        }
        let baseline = openDescriptorCount()
        try #require(baseline > 0)

        for _ in 0..<25 {
            let pty = try PTY.spawn(executable: "/usr/bin/true")
            _ = pty.waitForExit()
            pty.close()
        }

        let after = openDescriptorCount()
        // Slack for unrelated transients in the shared test process; a real
        // leak would grow by one descriptor per iteration.
        #expect(
            after <= baseline + 2,
            "descriptor count grew from \(baseline) to \(after) over 25 spawn/close cycles")
    }

    @Test("a failed spawn leaks no descriptors")
    func failedSpawnLeaksNoDescriptors() throws {
        _ = try? PTY.spawn(executable: "/nonexistent/corta-does-not-exist")
        let baseline = openDescriptorCount()
        try #require(baseline > 0)

        for _ in 0..<10 {
            #expect(throws: PTYError.spawnFailed(code: ENOENT)) {
                try PTY.spawn(executable: "/nonexistent/corta-does-not-exist")
            }
        }

        let after = openDescriptorCount()
        #expect(
            after <= baseline + 2,
            "descriptor count grew from \(baseline) to \(after) over 10 failed spawns")
    }

    // MARK: Foreground/background tracking

    @Test("foreground tracking follows job control")
    func foregroundTrackingFollowsJobControl() throws {
        // Only an interactive shell does job control. bash, not zsh: zsh
        // keeps MONITOR off when it cannot take the tty's process group at
        // startup, which this spawn order (session leader first, ctty
        // second) triggers; bash --norc -i works and reads no user rc.
        // Writing before the prompt appears loses the bytes to readline's
        // setup, so readiness is the prompt, not the clock.
        let pty = try PTY.spawn(executable: "/bin/bash", arguments: ["--norc", "-i"])
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }

        _ = pty.readOutput(containing: "$ ")

        // At the prompt the shell itself owns the terminal: no foreground
        // job, and the active name is the shell's.
        #expect(waitForCondition { pty.foregroundProcessGroup == pty.processIdentifier })
        #expect(pty.hasForegroundJob == false)
        #expect(pty.activeProcessName == "bash")
        #expect(pty.foregroundProcessName == nil)

        // A foreground command takes the terminal over.
        try pty.write(text: "sleep 30\n")
        #expect(waitForCondition { pty.hasForegroundJob })
        #expect(pty.foregroundProcessName == "sleep")

        // ^Z suspends it; ownership returns to the shell.
        try pty.write(text: "\u{1A}")
        #expect(waitForCondition { pty.hasForegroundJob == false })

        // bash 3.2 only reaps a killed job when the *next* command runs, so
        // the first `exit` can still meet a job table that says Stopped and
        // answer "There are stopped jobs." instead of exiting; the second
        // one goes through unconditionally. Either way the wait must keep
        // draining — see `waitForExitDraining`.
        try pty.write(text: "kill -KILL %1\n")
        _ = pty.readOutput(containing: "$ ", timeout: .seconds(5))
        try pty.write(text: "exit\n")
        var exit = waitForExitDraining(pty, timeout: .seconds(5))
        if exit == nil {
            try pty.write(text: "exit\n")
            exit = waitForExitDraining(pty)
        }
        #expect(exit != nil)
    }

    @Test("a background job does not own the terminal")
    func backgroundJobDoesNotOwnTheTerminal() throws {
        let pty = try PTY.spawn(executable: "/bin/bash", arguments: ["--norc", "-i"])
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }

        _ = pty.readOutput(containing: "$ ")
        #expect(waitForCondition { pty.foregroundProcessGroup == pty.processIdentifier })

        try pty.write(text: "sleep 30 &\n")
        // Bounded negative wait: job control prints the job line when the
        // background job starts, so once it is visible the kernel state has
        // settled and the shell must still own the terminal.
        #expect(pty.readOutput(containing: "[1]", timeout: .seconds(5)).contains("[1]"))
        #expect(pty.foregroundProcessGroup == pty.processIdentifier)
        #expect(pty.hasForegroundJob == false)

        // Two `exit`s, as in the foreground test: a killed job can still be
        // listed as stopped when the first one runs.
        try pty.write(text: "kill -KILL %1\n")
        _ = pty.readOutput(containing: "$ ", timeout: .seconds(5))
        try pty.write(text: "exit\n")
        var exit = waitForExitDraining(pty, timeout: .seconds(5))
        if exit == nil {
            try pty.write(text: "exit\n")
            exit = waitForExitDraining(pty)
        }
        #expect(exit != nil)
    }

    // MARK: Helpers

    /// Spawns a short-lived child, closes its pty, and reopens a file onto
    /// the recycled descriptor number, then runs `body` with both. Retries
    /// the whole cycle when a parallel suite's thread claims the number
    /// between close and reopen — suites run in parallel, and descriptors
    /// are a process-wide resource.
    private func withRecycledDescriptor(
        concurrentClose: Bool = false,
        _ body: (PTY, RecycledDescriptorFile) throws -> Void
    ) throws {
        for _ in 0..<10 {
            let pty = try PTY.spawn(executable: "/usr/bin/true")
            _ = pty.waitForExit()
            if concurrentClose {
                DispatchQueue.concurrentPerform(iterations: 64) { _ in pty.close() }
            } else {
                pty.close()
            }
            guard let file = RecycledDescriptorFile(recycling: pty.fileDescriptor) else {
                continue
            }
            defer { file.dispose() }
            try body(pty, file)
            return
        }
        Issue.record("the pty's descriptor number stayed claimed for 10 attempts")
    }

    /// Waits for the child to exit while continuing to drain the pty. An
    /// exiting session leader blocks in the kernel's tty output drain
    /// (`ttywait`) while unread output is pending, so a bare `waitForExit`
    /// after output nobody read never completes — the production reader
    /// thread is what normally hides this.
    private func waitForExitDraining(
        _ pty: PTY, timeout: Duration = .seconds(10)
    ) -> ChildExit? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            _ = pty.readOutput(timeout: .milliseconds(100))
            if let exit = pty.exitStatus { return exit }
        }
        return pty.waitForExit(timeout: .milliseconds(500))
    }

    /// Polls `condition` at 10 ms intervals for up to 10 seconds. Returns
    /// whether it ever held.
    private func waitForCondition(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// The number of descriptors this process holds, per `proc_pidinfo`.
    private func openDescriptorCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return -1 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.size
    }
}

/// A freshly created empty file whose descriptor has recycled a given
/// (already closed) descriptor number — the kernel hands out the lowest
/// free number, so reopening until the numbers match converges at once.
/// `nil` when another thread claimed the number first.
private final class RecycledDescriptorFile {
    let descriptor: Int32
    private let path: String
    private var spares: [Int32] = []

    init?(recycling target: Int32) {
        path = NSTemporaryDirectory() + "corta-fd-recycle-\(UUID().uuidString)"
        var descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        while descriptor >= 0, descriptor != target, spares.count < 64 {
            spares.append(descriptor)
            descriptor = open(path, O_RDWR, 0)
        }
        guard descriptor == target else {
            for spare in spares { Darwin.close(spare) }
            if descriptor >= 0 { Darwin.close(descriptor) }
            unlink(path)
            return nil
        }
        self.descriptor = descriptor
    }

    var byteCount: Int {
        var buffer = [UInt8](repeating: 0, count: 256)
        return pread(descriptor, &buffer, buffer.count, 0)
    }

    func dispose() {
        Darwin.close(descriptor)
        for spare in spares { Darwin.close(spare) }
        unlink(path)
    }
}
