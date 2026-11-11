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
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// What a shell may hold of this process's descriptors (its terminal on 0, 1
/// and 2, and nothing else: `SFTPChildDescriptorTests` and the app's
/// `ChildDescriptorTests` hold the other children to theirs), a number that stays
/// taken while a call on it is in flight, and a session that ends with its
/// shell even when a background job keeps the replica open.
///
/// `.serialized`: every test here spawns real children — see the
/// `.serialized` note on `TerminalSessionTests`.
@Suite("Descriptor hygiene", .serialized)
struct DescriptorHygieneTests {
    @Test("a spawned shell inherits none of this process's descriptors")
    func spawnedShellInheritsNothing() throws {
        // A pipe opened without close-on-exec — the shape of an SFTP pipe or
        // a file mid-transfer.
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer {
            close(ends[0])
            close(ends[1])
        }
        let leaked = ends[1]
        // Every number a child could be handed, not only this pipe's: anything
        // between 3 and 200 besides the replica on 0, 1 and 2 is a leak. A
        // duplicate onto an unused number rather than `-e /dev/fd/n`, which cannot
        // stat a shared-memory object; redirecting a number that is open (0, or
        // 2 per command) makes bash park the old one on 10, which then reads as held.
        let pty = try PTYFixture.shell(
            """
            [ -e /dev/fd/1 ] && echo CORTA-STDOUT-SEEN
            exec 2>/dev/null; open=; n=3
            while [ $n -le 200 ]; do ( exec 222<&$n ) && open="$open $n"; n=$((n + 1)); done
            echo "CORTA-OPEN:$open:END"
            """)
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }
        let output = pty.readOutput { $0.contains(":END") }
        // The probe can see a descriptor that is there.
        #expect(output.contains("CORTA-STDOUT-SEEN"))
        #expect(leaked <= 200, "the probe does not reach descriptor \(leaked)")
        #expect(output.contains("CORTA-OPEN::END"), "the shell held more than its terminal:\n\(output)")
    }

    /// #546 ended the old contract this test used to pin. The primary is
    /// non-blocking now, and a read that would block parks in a readiness
    /// wait that `close()` wakes, so a close during a read ends the read at
    /// once instead of leaving it parked in the kernel. The number stays held
    /// while the call is in flight — `GuardedDescriptorTests` pins that
    /// enter/leave order — and is released when the call leaves; the close
    /// wakeup makes that prompt rather than the child's lifetime.
    @Test("a close during a read ends the read at once and releases the number when it leaves")
    func closeDuringReadEndsTheReadAndReleasesTheNumber() throws {
        let pty = try PTYFixture.shell("sleep 30")
        defer {
            // The close hangs the child up; reap it.
            pty.terminate()
            _ = pty.waitForExit()
        }
        let returned = DispatchSemaphore(value: 0)
        let outcome = Mutex<Result<Int, PTYError>?>(nil)
        let reader = Thread {
            defer { returned.signal() }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 1)
            defer { buffer.deallocate() }
            do throws(PTYError) {
                let count = try pty.read(into: buffer)
                outcome.withLock { $0 = .success(count) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        reader.start()
        // The read has entered the guard and parked in its readiness wait;
        // the child writes nothing.
        let deadline = SuspendingClock.now + .seconds(10)
        while pty.callsInFlight == 0, SuspendingClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
        #expect(pty.callsInFlight == 1, "the reader never started its read")
        Thread.sleep(forTimeInterval: 0.01)

        // Darwin's `close(2)` would sleep until a kernel read returned — for
        // this child, until `sleep 30` ended. The close wakeup ends the read,
        // so the caller never waits and the call does not outlive it.
        let closeStarted = SuspendingClock.now
        pty.close()
        #expect(closeStarted.duration(to: .now) < .seconds(1))

        // The wakeup ends the parked call: it leaves, reports the close rather
        // than a byte, and the number is released with the last one out.
        let releasedDeadline = SuspendingClock.now + testTimeout(5)
        while pty.callsInFlight != 0, SuspendingClock.now < releasedDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(pty.callsInFlight == 0, "the close should end the parked read")
        #expect(pty.isClosed)
        #expect(outcome.withLock { $0 } == .failure(.closed), "the read must report the close")
        #expect(returned.wait(timeout: .now() + testTimeoutInterval(10)) == .success)
    }

    /// The kernel revokes a session's terminal when its leader exits, so a job
    /// that reopened `/dev/tty` and outlives the shell does not hold the
    /// session open. Pinned because the opposite was once reported as a bug.
    @Test("a session ends with its shell even when a background job keeps the terminal")
    func sessionEndsWhenTheShellExitsUnderABackgroundJob() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            // `nohup` would write `nohup.out` into the working directory.
            arguments: [
                "-c", "(trap '' HUP; exec sleep 10) </dev/tty >/dev/tty 2>&1 & sleep 0.2; exit 3",
            ])
        defer { session.stop() }
        let exited = Mutex<ProcessExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()

        // Well inside the job's 10 s, which ends it on its own afterwards
        // (it ignores the hangup `stop()` sends).
        let deadline = SuspendingClock.now + .seconds(5)
        while exited.withLock({ $0 }) == nil, SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(exited.withLock { $0 } == .exited(code: 3))
    }
}
