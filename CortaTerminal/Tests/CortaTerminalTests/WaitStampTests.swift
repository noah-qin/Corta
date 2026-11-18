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
import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// The reader reads the foreground group outside the session lock and stamps
/// the waits a slice began before it parses the next. Program signals read in
/// that gap must wait for the stamp: a wait seen unstamped reads as
/// unverified, and its notice would be lost (`SECURITY.md` §2.9).
@Suite("Wait stamps read outside the lock")
struct WaitStampTests {
    @Test("no reader sees a wait before it is stamped")
    func noUnstampedWaitIsSeen() throws {
        let cycle = Array("\u{1B}]7501;state=working\u{1B}\\x\u{1B}]7501;state=blocked:kind=permission\u{1B}\\".utf8)
        // One wait begun in every slice: a slice ends where the batch does.
        let chunks = Mutex((0..<2_000).map { _ in cycle }[...])
        var seams = TerminalSession.Seams()
        seams.readerSource = ReaderSource(
            read: { buffer in
                chunks.withLock { rest in
                    guard let chunk = rest.popFirst() else { return 0 }
                    chunk.withUnsafeBytes { buffer.copyMemory(from: $0) }
                    return chunk.count
                }
            },
            isReadable: { false })
        seams.hangupGracePeriod = .milliseconds(100)
        let session = try TerminalSession(executable: "/bin/cat", seams: seams)
        defer { session.stop() }
        let finished = Mutex(false)
        session.onIOFailure = { _ in finished.withLock { $0 = true } }

        let unstamped = Mutex(0)
        let stamped = Mutex(0)
        let polling = Thread {
            while !finished.withLock({ $0 }) {
                guard let status = session.programStatuses[""], status.state == .blocked else { continue }
                if status.reporter == nil {
                    unstamped.withLock { $0 += 1 }
                } else {
                    stamped.withLock { $0 += 1 }
                }
            }
        }
        polling.start()
        session.start()
        let deadline = SuspendingClock.now + .seconds(60 * testTimeoutScale)
        while !finished.withLock({ $0 }), SuspendingClock.now < deadline { usleep(2_000) }
        #expect(finished.withLock { $0 })
        #expect(stamped.withLock { $0 } > 0)
        #expect(unstamped.withLock { $0 } == 0)
        #expect(session.programStatuses[""]?.reporter?.members.first?.name == "cat")
    }
}
