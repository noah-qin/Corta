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
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// Session lifecycle and reader batching boundaries.
///
/// `.serialized` and condition-based waits, for the same reasons as
/// `TerminalSessionTests`: every test spawns a real child.
@Suite(.serialized) struct TerminalSessionLifecycleTests {
    // MARK: Configure-before-start

    @Test func initDoesNotDrainUntilStartIsCalled() throws {
        let session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", "printf 'CORTA-NOT-YET'; sleep 30"])
        defer { session.stop() }

        // Negative check, so it is bounded and short: with no reader the
        // child's bytes sit in the pty and the grid must stay empty.
        let deadline = SuspendingClock.now + .milliseconds(300)
        while SuspendingClock.now < deadline {
            #expect(!session.snapshot().dump().contains("CORTA-NOT-YET"))
            Thread.sleep(forTimeInterval: 0.01)
        }

        session.start()
        let text = waitForGrid(session) { $0.contains("CORTA-NOT-YET") }
        #expect(
            text.contains("CORTA-NOT-YET"),
            "after start() the buffered output should reach the grid; grid held:\n\(text)")
    }

    @Test func childThatExitsBeforeStartStillReportsExit() throws {
        let session = try TerminalSession(executable: "/usr/bin/true")
        defer { session.stop() }

        // The child is gone before any reader exists.
        #expect(session.pty.waitForExit(timeout: .seconds(30)) != nil)

        let exited = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()

        let deadline = SuspendingClock.now + .seconds(30)
        while exited.withLock({ $0 }) == nil, SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(exited.withLock { $0 } == .exited(code: 0))
    }

    @Test func exitRecordedBeforeCallbackInstalledIsReplayed() throws {
        let session = try TerminalSession(executable: "/usr/bin/true")
        defer { session.stop() }
        let first = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in first.withLock { $0 = exit } }
        session.start()

        let deadline = SuspendingClock.now + .seconds(30)
        while first.withLock({ $0 }) == nil, SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(first.withLock { $0 } == .exited(code: 0))

        // Installing a callback after the exit was recorded must replay it —
        // synchronously, on this thread.
        let replayed = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in replayed.withLock { $0 = exit } }
        #expect(replayed.withLock { $0 } == .exited(code: 0))
    }

    @Test func outputWrittenBeforeStartIsSignaledAfterStart() throws {
        let session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", "printf 'CORTA-EARLY'; sleep 30"])
        defer { session.stop() }
        let fired = Mutex(false)
        session.onOutput = { fired.withLock { $0 = true } }
        session.start()

        let text = waitForGrid(session) { $0.contains("CORTA-EARLY") }
        #expect(
            text.contains("CORTA-EARLY"),
            "output buffered before start() should still be read; grid held:\n\(text)")
        #expect(fired.withLock { $0 })
    }

    /// #228: real input must still reach a live child after repeated quiet
    /// periods. Disable line-discipline echo so seeing a marker proves the
    /// child read it, rather than just the kernel echoing the write.
    @Test func inputAndOutputResumeAfterRepeatedIdlePeriods() async throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "stty -echo; printf 'CORTA-IDLE-READY\\n'; while IFS= read "
                    + "-r line; do printf 'CHILD:%s\\n' \"$line\"; done",
            ])
        defer { session.stop() }
        let outputs = Mutex(0)
        session.onOutput = { outputs.withLock { $0 += 1 } }
        session.start()
        #expect(waitForGrid(session) { $0.contains("CORTA-IDLE-READY") }
            .contains("CORTA-IDLE-READY"))

        for cycle in 0..<3 {
            // This silence is the test stimulus: it spans several 250 ms
            // reader polls. Completion is still awaited by condition.
            try await Task.sleep(for: .seconds(1))
            let before = outputs.withLock { $0 }
            let marker = "IDLE-\(cycle)"
            #expect(session.write(Array("\(marker)\n".utf8)) == .accepted)
            let text = waitForGrid(session) { $0.contains("CHILD:\(marker)") }
            #expect(text.contains("CHILD:\(marker)"))
            let deadline = SuspendingClock.now + .seconds(5)
            while outputs.withLock({ $0 }) == before, SuspendingClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(outputs.withLock { $0 } > before,
                "resumed output must also notify the frame loop")
        }
    }

    // MARK: Chunk-boundary batching

    /// An exact chunk-multiple burst must be applied without waiting for
    /// more input. The scripted source returns precisely one chunk, which a
    /// real pty's kernel buffering cannot be made to guarantee — this is the
    /// deterministic half.
    @Test func exactChunkBoundaryIsAppliedWithoutFurtherInput() throws {
        let source = ScriptedReaderSource()
        let session = try TerminalSession(
            executable: "/bin/cat", seams: .init(readerSource: source.source))
        // stop() first, then endOfFile(): the reader is blocked in the
        // scripted read, and stop()'s SIGCHLD lets waitForExit return the
        // moment the read unblocks.
        defer { source.endOfFile() }
        defer { session.stop() }
        session.start()

        let chunk = [UInt8](repeating: UInt8(ascii: "a"), count: TerminalSession.readChunkSize - 9)
            + Array("CHUNK-END".utf8)
        source.feed(chunk)

        let text = waitForGrid(session, timeout: .seconds(10)) { $0.contains("CHUNK-END") }
        #expect(
            text.contains("CHUNK-END"),
            "an exact 64 KiB chunk must reach the grid with no further input; grid tail:\n\(text.suffix(200))")
    }

    /// The end-to-end half: real ptys, writes of exactly 64 KiB,
    /// 128 KiB and 64 KiB + 1, each followed by silence. The marker is the
    /// write's tail, so it can only appear once every byte before it has
    /// been drained and applied.
    @Test func chunkSizedWritesReachTheGridWithoutFurtherInput() throws {
        let marker = "CORTA-END"
        for size in [65_536, 131_072, 65_537] {
            let script =
                "head -c \(size - marker.count) /dev/zero | tr '\\000' 'a'; "
                + "printf '%s' '\(marker)'; sleep 30"
            let session = try TerminalSession(executable: "/bin/sh", arguments: ["-c", script])
            defer { session.stop() }
            session.start()

            let text = waitForGrid(session, timeout: .seconds(15)) { $0.contains(marker) }
            #expect(
                text.contains(marker),
                "a \(size)-byte write must reach the grid with no further input; grid tail:\n\(text.suffix(200))")
        }
    }

    // MARK: Closing

    /// `SECURITY.md` §4.4: closing a pane stops what was in it. A group that
    /// ignored `SIGHUP` ran on after the pane closed, unreaped once it ended.
    @Test func aGroupThatIgnoresHangupIsKilledAfterTheGracePeriod() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' HUP; printf 'CORTA-IGNORING'; while :; do sleep 1; done"],
            seams: .init(hangupGracePeriod: .milliseconds(300)))
        let exited = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()
        _ = waitForGrid(session) { $0.contains("CORTA-IGNORING") }
        session.stop()

        let deadline = SuspendingClock.now + .seconds(10)
        while exited.withLock({ $0 }) == nil, SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(exited.withLock { $0 } == .signalled(signal: SIGKILL))
        #expect(session.pty.exitStatus == .signalled(signal: SIGKILL))
    }

    @Test func aChildThatHonoursHangupIsNotKilled() throws {
        let session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", "printf 'CORTA-READY'; sleep 30"],
            seams: .init(hangupGracePeriod: .seconds(5)))
        session.start()
        _ = waitForGrid(session) { $0.contains("CORTA-READY") }
        session.stop()
        #expect(session.pty.waitForExit(timeout: .seconds(5)) == .signalled(signal: SIGHUP))
    }

    /// #546: a write the kernel parked on a child that stopped reading held
    /// the writer thread, the primary and the session for as long as that
    /// child lived — and because the primary stayed open, the child never saw
    /// the hangup closing a terminal delivers. The writer now waits on the
    /// close wakeup as the reader does, so `stop()` ends the parked write at
    /// once and the descriptor is released.
    ///
    /// The job gets its own process group and the terminal (`set -m`) and
    /// ignores `SIGHUP`, so it outlives the hangup and the shell's own
    /// `SIGKILL` just as a real job does; it only reads the terminal once the
    /// test asks it to, which is what keeps the kernel's input buffer full.
    @Test func aParkedWriteEndsWhenThePaneCloses() throws {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-parked-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: result) }
        let session = try TerminalSession(
            executable: "/bin/bash",
            arguments: ["--norc", "-c", Self.neverReadingJob(reportingTo: result)],
            seams: .init(hangupGracePeriod: .seconds(5)))
        let jobGroup = Mutex<pid_t?>(nil)
        defer {
            if let group = jobGroup.withLock({ $0 }) { kill(-group, SIGKILL) }
            session.stop()
            _ = session.pty.waitForExit(timeout: .seconds(5))
        }
        session.start()

        let ready = waitForGrid(session) { $0.contains("CORTA-PARKED") }
        #expect(
            ready.contains("CORTA-PARKED"),
            "the job should reach its never-reading loop; grid held:\n\(ready)")
        let group = try #require(waitForTerminalJob(session), "the job should own the terminal")
        jobGroup.withLock { $0 = group }

        #expect(awaitParkedWriter(session), "the writer should be parked on the full primary")
        session.stop()
        #expect(
            waitUntil({ session.pty.callsInFlight == 0 }, timeout: testTimeout(2)),
            "a parked write kept a system call in flight after stop()")
        #expect(session.pty.isClosed, "the primary should be closed by stop()")

        // The job ignored the hangup and kept the terminal; once the primary
        // is closed, a read on it has to end rather than park.
        #expect(kill(-group, SIGUSR1) == 0, "the terminal's job should still run after the close")
        let exitCode = awaitReport(at: result)
        #expect(
            exitCode == "0" || exitCode == "1",
            "reading the closed terminal should end; cat exited \(String(describing: exitCode))")
    }

    /// A shell that starts one job in its own process group and on the
    /// terminal (`set -m`), both ignoring `SIGHUP`. The job never reads the
    /// terminal until it gets `SIGUSR1`, then reads to end of file or `EIO`
    /// and writes `cat`'s status to `result`. The trailing `:` keeps bash from
    /// `exec`ing its last command, which would leave the job in the shell's
    /// own process group; a shell that hung up instead of ignoring `SIGHUP`
    /// would revoke the terminal and end the parked write for the wrong
    /// reason.
    private static func neverReadingJob(reportingTo result: URL) -> String {
        """
        trap '' HUP
        set -m
        stty raw -echo
        /bin/bash --norc -c 'trap "" HUP; readNow=; trap "readNow=1" USR1; \
        printf "CORTA-PARKED\\n"; while [ -z "$readNow" ]; do sleep 0.02; done; \
        cat >/dev/null; printf "%s" $? > "\(result.path)"'
        :
        """
    }

    /// Queues 64 KiB — more than the kernel's terminal input buffer — and
    /// waits for the writer to park on it, with the reader's own readiness
    /// wait as the other system call in flight.
    private func awaitParkedWriter(_ session: TerminalSession) -> Bool {
        session.write([UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024))
        return waitUntil({ session.pty.callsInFlight >= 2 }, timeout: testTimeout(10))
    }

    /// The job that owns the terminal, once job control has handed it over.
    private func waitForTerminalJob(_ session: TerminalSession) -> pid_t? {
        let deadline = SuspendingClock.now + testTimeout(10)
        while SuspendingClock.now < deadline {
            if let group = session.pty.foregroundProcessGroup,
                group != session.pty.processIdentifier
            {
                return group
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    /// The status the job wrote after reading the closed terminal.
    private func awaitReport(at url: URL) -> String? {
        let deadline = SuspendingClock.now + testTimeout(5)
        while SuspendingClock.now < deadline {
            if let report = try? String(contentsOf: url, encoding: .utf8) { return report }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    /// Waits until `condition` holds, up to `timeout`: a bounded wait on
    /// `SuspendingClock`, which a closed lid cannot spend.
    private func waitUntil(_ condition: () -> Bool, timeout: Duration) -> Bool {
        let deadline = SuspendingClock.now + timeout
        while !condition(), SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
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
}

/// A scripted `ReaderSource`: `read` hands out exactly the fed bytes (up to
/// the requested count) and blocks while empty until `feed` or `endOfFile`.
private final class ScriptedReaderSource: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = [UInt8]()
    private var isAtEnd = false

    func feed(_ bytes: [UInt8]) {
        condition.lock()
        pending.append(contentsOf: bytes)
        condition.signal()
        condition.unlock()
    }

    func endOfFile() {
        condition.lock()
        isAtEnd = true
        condition.signal()
        condition.unlock()
    }

    var source: ReaderSource {
        ReaderSource(
            read: { [self] buffer in
                condition.lock()
                defer { condition.unlock() }
                while pending.isEmpty && !isAtEnd { condition.wait() }
                guard !pending.isEmpty else { return 0 }
                let count = min(buffer.count, pending.count)
                pending.withUnsafeBytes { bytes in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
                }
                pending.removeFirst(count)
                return count
            },
            isReadable: { [self] in
                condition.lock()
                defer { condition.unlock() }
                return !pending.isEmpty
            }
        )
    }
}
