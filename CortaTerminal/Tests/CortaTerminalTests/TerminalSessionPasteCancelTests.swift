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

import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// A paste is queued as a unit Ctrl-C can take back out: what is still
/// queued is dropped, keystrokes typed after it stay, and a bracketed paste
/// the child started reading is closed so the shell leaves paste mode. The
/// `writerSink` seam holds the first chunk "in the pty" so the queue behind
/// it is observable; waits are on conditions, deadlines only hang ceilings.
@Suite(.serialized) struct TerminalSessionPasteCancelTests {
    private static let closing: [UInt8] = Array("\u{1B}[201~".utf8)

    /// A sink that records every chunk and parks the first until released.
    private final class GatedSink: Sendable {
        let recorded = Mutex<[[UInt8]]>([])
        let released = Mutex(false)

        func write(_ chunk: [UInt8]) {
            let isFirst = recorded.withLock { chunks -> Bool in
                chunks.append(chunk)
                return chunks.count == 1
            }
            guard isFirst else { return }
            let deadline = ContinuousClock.now + testTimeout(10)
            while !released.withLock({ $0 }), ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        var chunks: [[UInt8]] { recorded.withLock { $0 } }
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + testTimeout(5)
        while !condition(), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        return condition()
    }

    private func makeSession(_ sink: GatedSink) throws -> TerminalSession {
        var seams = TerminalSession.Seams()
        seams.writerSink = { sink.write($0) }
        return try TerminalSession(executable: "/bin/cat", seams: seams)
    }

    @Test func cancellingAStartedBracketedPasteClosesItAndKeepsLaterKeystrokes() throws {
        let sink = GatedSink()
        let session = try makeSession(sink)
        defer { session.stop() }
        let first: [UInt8] = Array("\u{1B}[200~one".utf8)
        let rest: [[UInt8]] = [Array("two".utf8), Array("three\u{1B}[201~".utf8)]
        #expect(session.write(paste: [first] + rest, closing: Self.closing) == .accepted)
        #expect(wait { sink.chunks.count == 1 }, "the first chunk should reach the pty")
        #expect(session.hasPendingPaste)
        #expect(session.write([0x03]) == .accepted)

        #expect(session.cancelPendingPastes())
        #expect(!session.hasPendingPaste)
        sink.released.withLock { $0 = true }

        #expect(wait { sink.chunks.count == 3 })
        #expect(sink.chunks == [first, Self.closing, [0x03]])
    }

    @Test func aPasteNothingOfWhichWasSentIsDroppedWithoutAClosingMarker() throws {
        let sink = GatedSink()
        let session = try makeSession(sink)
        defer { session.stop() }
        // A keystroke holds the pty, so the whole paste is still queued.
        #expect(session.write([0x61]) == .accepted)
        #expect(wait { sink.chunks.count == 1 })
        #expect(session.write(paste: [Array("\u{1B}[200~x\u{1B}[201~".utf8)], closing: Self.closing) == .accepted)
        #expect(session.write([0x62]) == .accepted)

        #expect(session.cancelPendingPastes())
        sink.released.withLock { $0 = true }

        #expect(wait { sink.chunks.count == 2 })
        Thread.sleep(forTimeInterval: 0.05)
        #expect(sink.chunks == [[0x61], [0x62]])
    }

    @Test func cancellingWithNoPasteQueuedChangesNothing() throws {
        let sink = GatedSink()
        sink.released.withLock { $0 = true }
        let session = try makeSession(sink)
        defer { session.stop() }
        #expect(!session.cancelPendingPastes())
        #expect(session.write(paste: [[0x61], [0x62]], closing: nil) == .accepted)
        #expect(wait { sink.chunks.count == 2 })
        #expect(wait { !session.hasPendingPaste }, "a drained paste is no longer pending")
        #expect(!session.cancelPendingPastes())
    }

    /// Past the back-pressure cap a keystroke is refused; dropping the paste
    /// that filled the queue is what lets Ctrl-C through.
    @Test func cancellingAPasteOverTheCapAdmitsTheNextKeystroke() throws {
        let sink = GatedSink()
        let session = try makeSession(sink)
        defer { session.stop() }
        let chunk = [UInt8](repeating: 0x61, count: 64 * 1024)
        let paste = Array(repeating: chunk, count: 80)  // 5 MiB, over the 4 MiB cap
        #expect(session.write(paste: paste, closing: nil) == .accepted)
        #expect(wait { sink.chunks.count == 1 })
        #expect(session.write([0x03]) == .backpressured)

        #expect(session.cancelPendingPastes())
        #expect(session.write([0x03]) == .accepted)
        sink.released.withLock { $0 = true }
        #expect(wait { sink.chunks.count == 2 })
        #expect(sink.chunks.last == [0x03])
    }
}
