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

/// A region scroll turns the ring and puts back the rows outside the region
/// when that is cheaper than rotating the region (`ScreenLines.rotate`). Each
/// row here carries an identity in its first cell, so a wrong order, a lost
/// row or a revision that did not travel with its row shows up by name.
@Suite("Region scroll")
struct RegionScrollTests {
    /// What a recycled row reads as in its first cell: a space.
    private static let blank: UInt32 = 0x20

    /// `rows` rows holding identities 100..<100 + rows. A non-zero `turned` moves the
    /// ring's head first, so a region crosses the physical end of the buffer.
    private func numbered(_ rows: Int, turned: Int = 0) -> ScreenLines {
        var lines = ScreenLines(repeating: Line(), count: rows)
        if turned > 0 { lines.rotateUp(turned) }
        for row in 0..<rows { lines[row][0].scalar = UInt32(100 + row) }
        return lines
    }

    private func identities(_ lines: ScreenLines) -> [UInt32] {
        (0..<lines.count).map { lines[$0][0].scalar }
    }

    /// The same scroll on a plain array: rows `top...bottom` move by `delta`
    /// and the exposed ones become blank (identity 0).
    private func reference(_ rows: [UInt32], top: Int, bottom: Int, by delta: Int) -> [UInt32] {
        let count = min(abs(delta), bottom - top + 1)
        guard count > 0 else { return rows }
        let region = Array(rows[top...bottom])
        let blanks = Array(repeating: Self.blank, count: count)
        let moved = delta > 0 ? Array(region.dropFirst(count)) + blanks : blanks + Array(region.dropLast(count))
        var result = rows
        result.replaceSubrange(top...bottom, with: moved)
        return result
    }

    /// The first character of each of the first `rows` rows; `.` for a blank one.
    private func letters(_ grid: Grid, rows: Int = 20) -> String {
        String((0..<rows).map { row -> Character in
            let scalar = grid.lines[row][0].scalar
            return scalar == 0 || scalar == Self.blank ? "." : Character(Unicode.Scalar(scalar)!)
        })
    }

    /// Twenty rows, `a` to `t`, with the cursor on the last one.
    private func lettered() -> Terminal {
        var terminal = Terminal(rows: 20, columns: 10)
        let text = (0..<20).map { String(UnicodeScalar(UInt8(0x61 + $0))) }.joined(separator: "\r\n")
        terminal.feed(Array(text.utf8))
        return terminal
    }

    // MARK: Region shapes on the ring

    /// Header and footer, footer only, header only, and both at a wider margin,
    /// at a height where the ring path is taken.
    @Test(arguments: [(1, 19), (0, 18), (2, 19), (3, 17)])
    func tallRegionScrollsMatchTheReferenceInBothDirections(top: Int, bottom: Int) {
        for turned in [0, 7] {
            for delta in [1, 2, 3, -1, -2, -3] {
                var lines = numbered(20, turned: turned)
                let expected = reference(identities(lines), top: top, bottom: bottom, by: delta)
                lines.rotate(top: top, bottom: bottom, by: delta)
                #expect(identities(lines) == expected, "\(top)...\(bottom) by \(delta), head turned \(turned)")
            }
        }
    }

    @Test func aCountBeyondTheRegionBlanksTheRegionAndLeavesTheRestAlone() {
        for delta in [5, 6, 40, -5, -6, -40] {
            var lines = numbered(20)
            lines.rotate(top: 4, bottom: 8, by: delta)
            #expect(identities(lines) == reference(identities(numbered(20)), top: 4, bottom: 8, by: delta))
            #expect(lines.scrollEvent(at: 0) == ScrollEvent(top: 4, bottom: 8, delta: delta > 0 ? 5 : -5))
        }
    }

    @Test func aScrollOfTheWholeScreenBlanksEveryRow() {
        var lines = numbered(8)
        lines.rotate(top: 0, bottom: 7, by: 8)
        #expect(identities(lines) == Array(repeating: Self.blank, count: 8))
        lines = numbered(8, turned: 3)
        lines.rotate(top: 0, bottom: 7, by: -3)
        #expect(identities(lines) == [Self.blank, Self.blank, Self.blank, 100, 101, 102, 103, 104])
    }

    @Test func aOneRowRegionIsBlankedInPlace() {
        var lines = numbered(10)
        lines.rotate(top: 4, bottom: 4, by: 1)
        #expect(identities(lines) == [100, 101, 102, 103, Self.blank, 105, 106, 107, 108, 109])
    }

    @Test func theRingHeadStaysInsideTheStorageWhenTheTurnWraps() {
        var lines = numbered(30)
        // Every scroll turns the ring, so the head wraps many times; a stray
        // index would trap in `physicalIndex`.
        for step in 0..<200 {
            lines.rotate(top: 1, bottom: 28, by: step.isMultiple(of: 3) ? -2 : 1)
        }
        #expect(lines.count == 30)
        #expect(lines[0][0].scalar == 100 && lines[29][0].scalar == 129, "header and footer never moved")
    }

    // MARK: Revisions and the journal

    @Test func revisionsTravelWithTheirRowsAndOnlyExposedRowsAreStamped() {
        for delta in [1, 3, -1, -3] {
            var lines = numbered(20, turned: 5)
            var before: [UInt32: UInt64] = [:]
            for row in 0..<20 { before[lines[row][0].scalar] = lines.revision(at: row) }
            let newest = before.values.max()!
            lines.rotate(top: 2, bottom: 17, by: delta)
            let exposed = delta > 0 ? Array((18 - delta)...17) : Array(2...(1 - delta))
            for row in 0..<20 {
                if exposed.contains(row) {
                    #expect(lines[row].isEmpty)
                    #expect(lines.revision(at: row) > newest, "exposed row \(row) is stamped")
                } else {
                    #expect(lines.revision(at: row) == before[lines[row][0].scalar], "row \(row) by \(delta)")
                }
            }
        }
    }

    @Test func theScrollEventIsRecordedOncePerScroll() {
        var lines = numbered(20)
        lines.rotate(top: 1, bottom: 19, by: 2)
        lines.rotate(top: 1, bottom: 19, by: -1)
        #expect(lines.scrollEventsTotal == 2)
        #expect(lines.scrollEvent(at: 0) == ScrollEvent(top: 1, bottom: 19, delta: 2))
        #expect(lines.scrollEvent(at: 1) == ScrollEvent(top: 1, bottom: 19, delta: -1))
    }

    /// Both paths against a naive model, over random regions, counts and
    /// directions, on a ring whose head keeps moving.
    @Test func randomRegionScrollsMatchANaiveModel() {
        var generator = SplitMix(seed: 547)
        var fresh: UInt32 = 1_000
        for rows in [2, 3, 5, 12, 40, 90] {
            var lines = numbered(rows)
            var model = identities(lines)
            for _ in 0..<400 {
                if generator.next() % 8 == 0 {
                    lines.rotateUp(1)
                    model = Array(model.dropFirst()) + [Self.blank]
                }
                // Give blank rows a name so each row is told apart.
                for row in 0..<rows where model[row] == Self.blank {
                    fresh += 1
                    lines[row][0].scalar = fresh
                    model[row] = fresh
                }
                var revisions: [UInt32: UInt64] = [:]
                for row in 0..<rows { revisions[model[row]] = lines.revision(at: row) }
                let newest = revisions.values.max()!

                let top = Int(generator.next() % UInt64(rows))
                let bottom = top + Int(generator.next() % UInt64(rows - top))
                let size = Int(generator.next() % UInt64(rows + 2)) + 1
                let delta = generator.next() % 2 == 0 ? size : -size
                lines.rotate(top: top, bottom: bottom, by: delta)
                model = reference(model, top: top, bottom: bottom, by: delta)

                #expect(identities(lines) == model, "\(rows) rows, \(top)...\(bottom) by \(delta)")
                for row in 0..<rows {
                    if model[row] == Self.blank {
                        #expect(lines.revision(at: row) > newest, "exposed row \(row) is stamped")
                    } else {
                        #expect(lines.revision(at: row) == revisions[model[row]], "row \(row) kept its revision")
                    }
                }
            }
        }
    }

    // MARK: Through the terminal

    @Test func linefeedsAtTheBottomMarginScrollTheRegionAndKeepHeaderAndFooter() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r\u{1B}[19;1H\n\n\n".utf8))
        #expect(letters(terminal.grid) == "aefghijklmnopqrs...t")
    }

    @Test func scrollUpInsideBothMargins() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r\u{1B}[2S".utf8))
        #expect(letters(terminal.grid) == "adefghijklmnopqrs..t")
    }

    @Test func scrollDownInsideBothMargins() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r\u{1B}[2T".utf8))
        #expect(letters(terminal.grid) == "a..bcdefghijklmnopqt")
    }

    @Test func headerOnlyAndFooterOnlyRegions() {
        var header = lettered()
        header.feed(Array("\u{1B}[3;20r\u{1B}[1S".utf8))
        #expect(letters(header.grid) == "abdefghijklmnopqrst.")
        var footer = lettered()
        footer.feed(Array("\u{1B}[1;19r\u{1B}[1S".utf8))
        #expect(letters(footer.grid) == "bcdefghijklmnopqrs.t")
        footer.feed(Array("\u{1B}[1T".utf8))
        #expect(letters(footer.grid) == ".bcdefghijklmnopqrst")
    }

    @Test func aCountLargerThanTheRegionBlanksOnlyTheRegion() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r\u{1B}[99S".utf8))
        #expect(letters(terminal.grid) == "a..................t")
    }

    @Test func insertAndDeleteLinesInsideARegion() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r\u{1B}[5;1H\u{1B}[2L".utf8))
        #expect(letters(terminal.grid) == "abcd..efghijklmnopqt")
        terminal.feed(Array("\u{1B}[3M".utf8))
        #expect(letters(terminal.grid) == "abcdfghijklmnopq...t")
    }

    @Test func aSnapshotTakenBeforeARegionScrollIsUnchangedByIt() {
        var terminal = lettered()
        terminal.feed(Array("\u{1B}[2;19r".utf8))
        let snapshot = terminal.grid
        let revisions = (0..<20).map { snapshot.lines.revision(at: $0) }
        terminal.feed(Array("\u{1B}[19;1H\n\n\u{1B}[1T\u{1B}[3;1H\u{1B}[1L\u{1B}[2S".utf8))
        #expect(letters(terminal.grid) != "abcdefghijklmnopqrst")
        #expect(letters(snapshot) == "abcdefghijklmnopqrst")
        #expect((0..<20).map { snapshot.lines.revision(at: $0) } == revisions)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
