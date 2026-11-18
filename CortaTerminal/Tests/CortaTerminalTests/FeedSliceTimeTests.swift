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

/// A parse slice is bounded by its time under the session lock as well as by
/// its bytes. The costs are modelled on the figures in `PERFORMANCE.md` §5.30:
/// an erase under a background colour at 120 × 400 took 57.3 ms per 16,380
/// bytes, about 3.5 µs a byte; ASCII about 1.8 ns a byte.
@Suite("Feed slices bounded by time")
struct FeedSliceTimeTests {
    private static let eraseNanosecondsPerByte: UInt64 = 3_498
    private static let asciiNanosecondsPerByte: UInt64 = 2

    // MARK: - The sizer

    @Test("a slow stream settles under 8 ms a slice within a few slices")
    func slowStreamSettles() {
        var sizer = FeedSliceSizer(ceiling: TerminalSession.feedLockSliceSize)
        var held: [UInt64] = []
        for _ in 0..<64 {
            let time = UInt64(sizer.limit) * Self.eraseNanosecondsPerByte
            held.append(time)
            sizer.record(heldNanoseconds: time, bytes: sizer.limit)
        }
        #expect(held.dropFirst(4).allSatisfy { $0 <= 8_000_000 })
        #expect(sizer.limit == 1_024)
    }

    @Test("ordinary output keeps the full slice")
    func fastStreamKeepsTheCeiling() {
        var sizer = FeedSliceSizer(ceiling: TerminalSession.feedLockSliceSize)
        for _ in 0..<64 {
            sizer.record(heldNanoseconds: UInt64(sizer.limit) * Self.asciiNanosecondsPerByte, bytes: sizer.limit)
            #expect(sizer.limit == TerminalSession.feedLockSliceSize)
        }
    }

    @Test("the size stops at the floor, and grows back once slices are quick")
    func floorAndRecovery() {
        var sizer = FeedSliceSizer(ceiling: TerminalSession.feedLockSliceSize)
        for _ in 0..<20 { sizer.record(heldNanoseconds: 50_000_000, bytes: sizer.limit) }
        #expect(sizer.limit == FeedSliceSizer.floor)
        for _ in 0..<20 { sizer.record(heldNanoseconds: 100_000, bytes: sizer.limit) }
        #expect(sizer.limit == TerminalSession.feedLockSliceSize)
        // Between the two thresholds nothing moves.
        sizer.record(heldNanoseconds: 50_000_000, bytes: sizer.limit)
        let limit = sizer.limit
        sizer.record(heldNanoseconds: 2_000_000, bytes: limit)
        #expect(sizer.limit == limit)
    }

    /// A batch's last slice is often short and quick; it is no evidence that
    /// a full one would be.
    @Test("a short quick slice does not grow the next one")
    func shortSliceDoesNotGrow() {
        var sizer = FeedSliceSizer(ceiling: TerminalSession.feedLockSliceSize)
        for _ in 0..<4 { sizer.record(heldNanoseconds: 50_000_000, bytes: sizer.limit) }
        let limit = sizer.limit
        sizer.record(heldNanoseconds: 100_000, bytes: limit / 4)
        #expect(sizer.limit == limit)
        sizer.record(heldNanoseconds: 100_000, bytes: limit)
        #expect(sizer.limit == limit * 2)
    }

    // MARK: - The reader

    /// One clock read as the slice takes the lock, one as it lets go; the
    /// second makes the slice cost its size at the erase rate.
    private final class ModelClock: Sendable {
        private struct State {
            var now: UInt64 = 1_000_000_000
            var taken: UInt64?
            var held: [UInt64] = []
        }
        private let state = Mutex(State())
        let session = Mutex<TerminalSession?>(nil)

        func read() -> UInt64 {
            let limit = session.withLock { $0?.feedSliceLimit.load(ordering: .relaxed) } ?? 0
            return state.withLock { state in
                if let taken = state.taken {
                    let held = UInt64(limit) * FeedSliceTimeTests.eraseNanosecondsPerByte
                    state.now = taken + held
                    state.held.append(held)
                    state.taken = nil
                } else {
                    state.now += 1_000
                    state.taken = state.now
                }
                return state.now
            }
        }

        var held: [UInt64] { state.withLock { $0.held } }
    }

    /// The screen is small so a debug build does the real work quickly; the
    /// clock charges each slice what it cost at 120 × 400.
    @Test("an erase flood through the reader settles under 8 ms a slice")
    func readerSettlesUnderTheBound() throws {
        let unit = Array("\u{1B}[41m\u{1B}[2J".utf8)
        var stream: [UInt8] = []
        while stream.count < 64 * 1024 { stream += unit }
        let remaining = Mutex(stream[...])
        let clock = ModelClock()
        var seams = TerminalSession.Seams()
        seams.readerSource = ReaderSource(
            read: { buffer in
                remaining.withLock { rest in
                    let count = min(buffer.count, rest.count)
                    for (index, byte) in rest.prefix(count).enumerated() { buffer[index] = byte }
                    rest = rest.dropFirst(count)
                    return count
                }
            },
            isReadable: { !remaining.withLock { $0.isEmpty } })
        seams.sliceClock = { clock.read() }
        seams.hangupGracePeriod = .milliseconds(100)
        let session = try TerminalSession(
            executable: "/bin/cat", size: TerminalSize(rows: 24, columns: 80), seams: seams)
        defer { session.stop() }
        clock.session.withLock { $0 = session }
        // End of input with `cat` alive is reported once reading has finished.
        let finished = Mutex(false)
        session.onIOFailure = { _ in finished.withLock { $0 = true } }
        session.start()
        let deadline = SuspendingClock.now + .seconds(60 * testTimeoutScale)
        while !finished.withLock({ $0 }), SuspendingClock.now < deadline { usleep(2_000) }
        #expect(finished.withLock { $0 })

        let held = clock.held
        #expect(held.count > 20)
        #expect(held.dropFirst(4).allSatisfy { $0 <= 8_000_000 }, "\(held.prefix(8))")
        #expect(session.feedSliceLimit.load(ordering: .relaxed) == 1_024)
        // Smaller slices change nothing about what the screen ends up holding.
        let grid = session.snapshot()
        #expect(grid[23, 79].background == grid[0, 0].background)
        #expect(grid[0, 0].background != Cell().background)
    }
}
