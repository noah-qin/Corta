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

import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// What a shell may hold of this process's descriptors, a number that stays
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
        let pty = try PTYFixture.shell(
            """
            [ -e /dev/fd/1 ] && echo CORTA-STDOUT-SEEN
            if [ -e /dev/fd/\(leaked) ]; then echo CORTA-LEAKED; else echo CORTA-SEALED; fi
            """)
        defer {
            pty.terminate()
            _ = pty.waitForExit()
            pty.close()
        }
        let output = pty.readOutput { $0.contains("CORTA-LEAKED") || $0.contains("CORTA-SEALED") }
        // The probe can see a descriptor that is there.
        #expect(output.contains("CORTA-STDOUT-SEEN"))
        #expect(output.contains("CORTA-SEALED"), "the shell held descriptor \(leaked):\n\(output)")
    }

    @Test("a close during a read returns at once and keeps the number until the read does")
    func closeDuringReadKeepsTheNumber() throws {
        let pty = try PTYFixture.shell("sleep 30")
        defer {
            pty.terminate()
            _ = pty.waitForExit()
        }
        let number = pty.fileDescriptor
        let returned = DispatchSemaphore(value: 0)
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 64)
            _ = try? buffer.withUnsafeMutableBytes { try pty.read(into: $0) }
            returned.signal()
        }
        reader.start()
        // Long enough for the reader to be parked inside `read(2)`.
        Thread.sleep(forTimeInterval: 0.3)

        // Darwin's `close(2)` would sleep until the read returned — here,
        // until `sleep 30` ended. The caller may be the main thread.
        let closeStarted = ContinuousClock.now
        pty.close()
        #expect(ContinuousClock.now - closeStarted < .seconds(1))

        // The lowest free number is what `open` returns, so a released
        // number would come straight back here.
        let opened = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { if opened >= 0 { close(opened) } }
        #expect(opened != number, "a new file took the number a read was still using")

        #expect(pty.terminate())
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
        let exited = Mutex<ChildExit?>(nil)
        session.onChildExit = { exit in exited.withLock { $0 = exit } }
        session.start()

        // Well inside the job's 10 s, which ends it on its own afterwards
        // (it ignores the hangup `stop()` sends).
        let deadline = ContinuousClock.now + .seconds(5)
        while exited.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(exited.withLock { $0 } == .exited(code: 3))
    }
}
