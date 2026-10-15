// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import CortaPOSIX
import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// Synchronized-output (`?2026`) timeout and recovery.
///
/// `.serialized` and condition-based waits, for the same reasons as
/// `TerminalSessionTests`: every test spawns a real child.
@Suite(.serialized) struct SynchronizedOutputRecoveryTests {
    @Test func resetAndBeginInOneBatchStillArmRecovery() throws {
        let timers = ManualTimers()
        let session = try TerminalSession(executable: "/bin/sh", arguments: ["-c",
            "printf '\\033[?2026hFIRST\\033[?2026l'; IFS= read -r line; printf '\\033c\\033[?2026hRESET-HELD'; sleep 30"], seams: timers.seams)
        defer { session.stop() }
        session.start()
        #expect(waitForGrid(session) { $0.contains("FIRST") }.contains("FIRST"))
        // The first, already-ended episode's timer retires before RIS.
        #expect(waitForCondition(timers.count == 1, timeout: .seconds(30)))
        timers.fire(0)
        session.write(Array("go\n".utf8))
        #expect(waitForGrid(session) { $0.contains("RESET-HELD") }.contains("RESET-HELD"))
        #expect(waitForCondition(timers.count == 2, timeout: .seconds(30)), "RIS and a begin in one batch must arm a timer")
        timers.fire(1)
        #expect(!session.isSynchronizedOutputEnabled)
    }

    @Test func risNeverReusesAnEpisodeIdentity() {
        var terminal = Terminal()
        terminal.feed(Array("\u{1B}[?2026h\u{1B}[?2026l".utf8))
        let first = terminal.synchronizedOutputEpisode
        terminal.feed(Array("\u{1B}c\u{1B}[?2026h".utf8))
        #expect(terminal.synchronizedOutputEpisode > first)
        #expect(terminal.isSynchronizedOutputEnabled)
        let second = terminal.synchronizedOutputEpisode
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(!terminal.isSynchronizedOutputEnabled)
        #expect(terminal.synchronizedOutputEpisode == second)
    }

    @Test func anOldTimerCannotEndANewEpisodeAfterRIS() throws {
        let timers = ManualTimers()
        let session = try TerminalSession(executable: "/bin/sh", arguments: ["-c",
            "printf '\\033[?2026hFIRST\\033[?2026l'; IFS= read -r line; printf '\\033c\\033[?2026hNEW-HELD'; sleep 30"], seams: timers.seams)
        defer { session.stop() }
        session.start()
        #expect(waitForGrid(session) { $0.contains("FIRST") }.contains("FIRST"))
        session.write(Array("go\n".utf8))
        #expect(waitForGrid(session) { $0.contains("NEW-HELD") }.contains("NEW-HELD"))
        #expect(waitForCondition(timers.count == 2, timeout: .seconds(30)))
        // The first episode's deadline passes while the new one is held.
        timers.fire(0)
        #expect(session.isSynchronizedOutputEnabled, "an old timer must not end a new episode")
        timers.fire(1)
        #expect(!session.isSynchronizedOutputEnabled)
    }

    /// A child that begins an episode and never sends the DECRST: after the
    /// (shortened) timeout the session must end the episode itself and
    /// signal output again, so the shell's latched owed-present draws the
    /// withheld frames.
    @Test func missedResetIsRecoveredAfterTimeout() throws {
        let timers = ManualTimers()
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNC-HELD'; sleep 30"],
            seams: timers.seams)
        defer { session.stop() }
        let outputCount = Mutex(0)
        session.onOutput = { outputCount.withLock { $0 += 1 } }
        session.start()

        let text = waitForGrid(session) { $0.contains("CORTA-SYNC-HELD") }
        #expect(
            text.contains("CORTA-SYNC-HELD"),
            "the episode's bytes must reach the grid; grid held:\n\(text)")
        #expect(session.isSynchronizedOutputEnabled)

        let outputsBeforeRecovery = outputCount.withLock { $0 }
        #expect(waitForCondition(timers.count == 1, timeout: .seconds(30)))
        timers.fire(0)
        #expect(!session.isSynchronizedOutputEnabled, "a missed DECRST must be recovered by the timeout")
        #expect(
            outputCount.withLock { $0 } > outputsBeforeRecovery,
            "the timeout must signal output so the shell presents the withheld frames")
    }

    /// A well-behaved begin/end pair: the mode clears on the child's DECRST,
    /// and the recovery timer for that episode must not fire afterwards (it
    /// would manufacture an output signal for nothing).
    @Test func normalBeginEndIsNotAffectedByTimeout() throws {
        let timers = ManualTimers()
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNCED\\033[?2026l'; sleep 30"],
            seams: timers.seams)
        defer { session.stop() }
        let outputCount = Mutex(0)
        session.onOutput = { outputCount.withLock { $0 += 1 } }
        session.start()

        let text = waitForGrid(session) { $0.contains("CORTA-SYNCED") }
        #expect(
            text.contains("CORTA-SYNCED"),
            "a complete episode must reach the grid; grid held:\n\(text)")
        #expect(!session.isSynchronizedOutputEnabled)

        let outputsAfterEnd = outputCount.withLock { $0 }
        #expect(waitForCondition(timers.count == 1, timeout: .seconds(30)))
        timers.fire(0)
        #expect(outputCount.withLock { $0 } == outputsAfterEnd, "the ended episode's timer must be a no-op")
        #expect(!session.isSynchronizedOutputEnabled)
    }

    /// A child that exits mid-episode can never send the DECRST: the exit
    /// path clears the mode immediately, without waiting for the timeout
    /// (set far beyond the test's patience here, so only the exit path can
    /// have cleared it).
    @Test func childExitClearsSynchronizedOutput() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?2026hCORTA-SYNC-ORPHAN'"],
            seams: .init(synchronizedOutputTimeout: .seconds(30)))
        defer { session.stop() }
        let exited = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()

        let exitedReceived = waitForCondition(
            exited.withLock { $0 } != nil, timeout: .seconds(30))
        #expect(exitedReceived, "the child's exit must be reported")
        #expect(
            !session.isSynchronizedOutputEnabled,
            "child exit must end the episode, not wait out the timeout")
    }

    /// The session's `?2026` timeouts, armed into a list instead of a dispatch
    /// timer: a test fires each one when it means to.
    private final class ManualTimers: Sendable {
        private let armed = Mutex<[@Sendable () -> Void]>([])
        var count: Int { armed.withLock { $0.count } }
        var seams: TerminalSession.Seams {
            .init(scheduleSynchronizedOutputTimeout: { [self] _, expire in armed.withLock { $0.append(expire) } })
        }
        func fire(_ index: Int) { armed.withLock { $0[index] }() }
    }

    /// Polls the grid until `condition` accepts its dump, or the hang
    /// ceiling expires. Returns the last dump either way.
    private func waitForGrid(
        _ session: TerminalSession, timeout: Duration = .seconds(30),
        until condition: (String) -> Bool
    ) -> String {
        let deadline = SuspendingClock.now + timeout
        var dump = session.snapshot().dump()
        while !condition(dump), SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            dump = session.snapshot().dump()
        }
        return dump
    }

    /// Polls until `condition` holds; returns whether it ever did.
    private func waitForCondition(
        _ condition: @autoclosure () -> Bool, timeout: Duration
    ) -> Bool {
        let deadline = SuspendingClock.now + timeout
        while !condition(), SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}
