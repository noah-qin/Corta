import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// S03 — synchronized-output (`?2026`) timeout and recovery.
///
/// `.serialized` and condition-based waits, for the same reasons as
/// `TerminalSessionTests`: every test spawns a real child.
@Suite(.serialized) struct SynchronizedOutputRecoveryTests {
    /// A child that begins an episode and never sends the DECRST: after the
    /// (shortened) timeout the session must end the episode itself and
    /// signal output again, so the shell's latched owed-present draws the
    /// withheld frames.
    @Test func missedResetIsRecoveredAfterTimeout() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNC-HELD'; sleep 30"])
        defer { session.stop() }
        session.synchronizedOutputTimeout = .milliseconds(200)
        let outputCount = Mutex(0)
        session.onOutput = { outputCount.withLock { $0 += 1 } }
        session.start()

        let text = waitForGrid(session) { $0.contains("CORTA-SYNC-HELD") }
        #expect(
            text.contains("CORTA-SYNC-HELD"),
            "the episode's bytes must reach the grid; grid held:\n\(text)")
        #expect(session.isSynchronizedOutputEnabled)

        let outputsBeforeRecovery = outputCount.withLock { $0 }
        let recovered = waitForCondition(
            !session.isSynchronizedOutputEnabled, timeout: .seconds(10))
        #expect(recovered, "a missed DECRST must be recovered by the timeout")
        let recoveredSignal = waitForCondition(
            outputCount.withLock { $0 } > outputsBeforeRecovery, timeout: .seconds(10))
        #expect(
            recoveredSignal,
            "the timeout must signal output so the shell presents the withheld frames")
    }

    /// A well-behaved begin/end pair: the mode clears on the child's DECRST,
    /// and the recovery timer for that episode must not fire afterwards (it
    /// would manufacture an output signal for nothing).
    @Test func normalBeginEndIsNotAffectedByTimeout() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNCED\\033[?2026l'; sleep 30"])
        defer { session.stop() }
        session.synchronizedOutputTimeout = .milliseconds(200)
        let outputCount = Mutex(0)
        session.onOutput = { outputCount.withLock { $0 += 1 } }
        session.start()

        let text = waitForGrid(session) { $0.contains("CORTA-SYNCED") }
        #expect(
            text.contains("CORTA-SYNCED"),
            "a complete episode must reach the grid; grid held:\n\(text)")
        #expect(!session.isSynchronizedOutputEnabled)

        let outputsAfterEnd = outputCount.withLock { $0 }
        // Well past the timeout: the episode's timer must have been a no-op.
        Thread.sleep(forTimeInterval: 0.6)
        #expect(outputCount.withLock { $0 } == outputsAfterEnd)
        #expect(!session.isSynchronizedOutputEnabled)
    }

    /// A child that exits mid-episode can never send the DECRST: the exit
    /// path clears the mode immediately, without waiting for the timeout
    /// (set far beyond the test's patience here, so only the exit path can
    /// have cleared it).
    @Test func childExitClearsSynchronizedOutput() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNC-ORPHAN'"])
        defer { session.stop() }
        session.synchronizedOutputTimeout = .seconds(30)
        let exited = Mutex<ChildExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()

        let exitedReceived = waitForCondition(
            exited.withLock { $0 } != nil, timeout: .seconds(30))
        #expect(exitedReceived, "the child's exit must be reported")
        #expect(
            !session.isSynchronizedOutputEnabled,
            "child exit must end the episode, not wait out the timeout")
    }

    /// Polls the grid until `condition` accepts its dump, or the hang
    /// ceiling expires. Returns the last dump either way.
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

    /// Polls until `condition` holds; returns whether it ever did.
    private func waitForCondition(
        _ condition: @autoclosure () -> Bool, timeout: Duration
    ) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}
