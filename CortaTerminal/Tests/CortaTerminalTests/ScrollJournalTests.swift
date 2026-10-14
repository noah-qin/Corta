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

import Testing
@testable import CortaTerminal

struct ScrollJournalTests {
    @Test func revisionsMoveAndVacatedRowsAreStamped() {
        var lines = ScreenLines(repeating: Line(), count: 6)
        for row in 0..<6 { lines[row][0].scalar = UInt32(0x61 + row) }
        // Exercise a region that crosses the circular buffer's physical head.
        lines.rotateUp(2)
        let revisions = (0..<6).map { lines.revision(at: $0) }
        lines.rotate(top: 1, bottom: 4, by: -2)
        #expect(lines.revision(at: 3) == revisions[1])
        #expect(lines.revision(at: 4) == revisions[2])
        #expect(lines.revision(at: 1) != revisions[1])
        #expect(lines.revision(at: 0) == revisions[0])
        #expect(lines.revision(at: 5) == revisions[5])
        #expect(lines[1].isEmpty && lines[2].isEmpty)
    }

    /// The journal is a ring: once it has wrapped, each sequence still in
    /// it answers with its own event, not with whatever last took slot 0.
    @Test func theJournalAnswersByItsOwnSequenceAfterWrapping() {
        var lines = ScreenLines(repeating: Line(), count: 6)
        let capacity = ScreenLines.scrollEventCapacity
        for _ in 0..<capacity { lines.rotateUp(1) }
        lines.rotate(top: 1, bottom: 4, by: 1)
        lines.rotate(top: 2, bottom: 3, by: -1)
        let total = lines.scrollEventsTotal
        #expect(total == UInt64(capacity + 2))
        #expect(lines.scrollEvent(at: total - 2) == ScrollEvent(top: 1, bottom: 4, delta: 1))
        #expect(lines.scrollEvent(at: total - 1) == ScrollEvent(top: 2, bottom: 3, delta: -1))
        #expect(lines.scrollEvent(at: total - 3) == ScrollEvent(top: 0, bottom: 5, delta: 1))
        #expect(lines.scrollEvent(at: total - UInt64(capacity) - 1) == nil, "evicted from the ring")
    }

    /// IL and DL scroll the band from the cursor to the bottom margin: one
    /// journaled event the renderer can shift by, not a re-stamp of every row.
    @Test func insertAndDeleteLinesJournalTheirBand() {
        var terminal = Terminal(rows: 6, columns: 10)
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne\r\nf".utf8))
        let before = terminal.grid.scrollEventsTotal
        terminal.feed(Array("\u{1B}[3;1H\u{1B}[2L".utf8))
        #expect(terminal.grid.scrollEventsTotal == before + 1)
        #expect(terminal.grid.scrollEvent(at: before) == ScrollEvent(top: 2, bottom: 5, delta: -2))
        #expect((0..<6).map { terminal.grid.lines[$0].cells.first.map { Character(Unicode.Scalar($0.scalar)!) } ?? " " }
            == ["a", "b", " ", " ", "c", "d"])
        terminal.feed(Array("\u{1B}[1M".utf8))
        #expect(terminal.grid.scrollEvent(at: before + 1) == ScrollEvent(top: 2, bottom: 5, delta: 1))
        #expect((0..<6).map { terminal.grid.lines[$0].cells.first.map { Character(Unicode.Scalar($0.scalar)!) } ?? " " }
            == ["a", "b", " ", "c", "d", " "])
    }

    @Test func journalOrdersEventsAndRejectsOverflow() {
        var lines = ScreenLines(repeating: Line(), count: 6)
        lines.rotateUp(1)
        lines.rotate(top: 1, bottom: 4, by: -2)
        #expect(lines.scrollEventsTotal == 2)
        #expect(lines.scrollEvent(at: 0) == ScrollEvent(top: 0, bottom: 5, delta: 1))
        #expect(lines.scrollEvent(at: 1) == ScrollEvent(top: 1, bottom: 4, delta: -2))
        for _ in 0..<64 { lines.rotateUp(1) }
        #expect(lines.scrollEvent(at: 1) == nil)
        #expect(lines.scrollEvent(at: 2) != nil)
        #expect(lines.scrollEvent(at: 65) != nil)
        #expect(lines.scrollEvent(at: 66) == nil)
        let fresh = ScreenLines(repeating: Line(), count: 6)
        #expect(fresh.generation != lines.generation)
        #expect(fresh.scrollEventsTotal == 0 && fresh.scrollEvent(at: 0) == nil)
    }

    @Test func explicitSwapStampsBothRows() {
        var lines = ScreenLines(repeating: Line(), count: 4)
        lines[0][0].scalar = 0x61
        lines[1][0].scalar = 0x62
        let revisions = (0..<4).map { lines.revision(at: $0) }
        lines.swapAt(0, 1)
        #expect(lines[0][0].scalar == 0x62 && lines[1][0].scalar == 0x61)
        #expect(lines.revision(at: 0) != revisions[0] && lines.revision(at: 1) != revisions[1])
        #expect(lines.revision(at: 2) == revisions[2])
    }
}
