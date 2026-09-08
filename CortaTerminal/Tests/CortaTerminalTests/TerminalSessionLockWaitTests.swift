import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

// P02: a `snapshot()` from the render thread must not starve behind the
// reader's feed under an output flood. Releasing the lock between feed
// slices is not enough on its own — a woken `os_unfair_lock` waiter lands
// slower than the reader re-acquires — so the reader leaves a real gap
// whenever a waiter is registered (`TerminalSession.yieldToStateWaiters`).
//
// The per-call ceiling is a starvation bound, not a performance gate:
// measured values after the fix are ~0.001 ms p99 / ~0.24 ms max
// (`corta-bench`, "snapshot latency under flood"), while the pre-fix code
// produced 127–490 ms waits. 100 ms sits far above the fix and far below
// the failure mode, on a loaded machine included. The suite-wide 30 s
// ceiling only stops a genuinely wedged run (see TerminalSessionTests'
// header).
@Suite(.serialized) struct TerminalSessionLockWaitTests {
    @Test func snapshotDoesNotStarveDuringAnOutputFlood() throws {
        let session = try TerminalSession(
            executable: "/usr/bin/yes", size: TerminalSize(rows: 50, columns: 200))
        defer { session.stop() }
        session.start()

        // Establish the precondition by condition, not by the clock: the
        // flood is visible in the grid before sampling starts.
        let floodDeadline = ContinuousClock.now + .seconds(30)
        while !session.snapshot().dump().contains("y"), ContinuousClock.now < floodDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        // The render thread's QoS in the app — the lock-holder/waiter
        // priority relationship is part of the mechanism under test.
        let maxWaitNanos = Mutex<UInt64>(0)
        let sampled = Mutex(0)
        let samplerDone = Mutex(false)
        let sampler = Thread {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            for _ in 0..<500 {
                let start = DispatchTime.now()
                _ = session.snapshot()
                let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                maxWaitNanos.withLock { $0 = max($0, elapsed) }
                sampled.withLock { $0 += 1 }
            }
            samplerDone.withLock { $0 = true }
        }
        sampler.start()

        let hangCeiling = ContinuousClock.now + .seconds(30)
        while !samplerDone.withLock({ $0 }), ContinuousClock.now < hangCeiling {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(
            sampled.withLock { $0 } == 500,
            "500 snapshots should complete during a flood well inside 30 s; completed \(sampled.withLock { $0 })")
        #expect(
            maxWaitNanos.withLock { $0 } < 100_000_000,
            "a snapshot starved behind the feed for \(Double(maxWaitNanos.withLock { $0 }) / 1e6) ms")
    }
}
