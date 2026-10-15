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

/// A selection is dropped when the program rewrites the rows it covers in
/// place, and kept when output only scrolls it into history or touches
/// other rows (#341).
@Suite("Selection content")
struct SelectionContentTests {
    /// Ten numbered rows on a 6-row screen, the selection on screen row 2
    /// ("7"), the cursor parked below it.
    private func selected() -> (Terminal, SelectionContent) {
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array((0..<10).map { "\($0)" }.joined(separator: "\r\n").utf8))
        let range = SelectionRange(
            start: SelectionPoint(row: 2, column: 0), end: SelectionPoint(row: 2, column: 5))
        #expect(Selection.text(of: range, in: terminal.grid) == "6")
        return (terminal, Selection.content(of: range, in: terminal.grid))
    }

    /// Moves to the selected row (screen row 2 is line 3), applies `sequence`,
    /// and puts the cursor back on the last row.
    private func onSelectedRow(_ sequence: String) -> Bool {
        var (terminal, content) = selected()
        terminal.feed(Array("\u{1B}7\u{1B}[3;1H\(sequence)\u{1B}8".utf8))
        return Selection.isUnchanged(content, in: terminal.grid)
    }

    @Test("output that only scrolls keeps the selection")
    func scrollingKeepsIt() {
        var (terminal, content) = selected()
        terminal.feed(Array("\r\nmore\r\nand more".utf8))
        #expect(Selection.isUnchanged(content, in: terminal.grid))
        terminal.feed(Array(String(repeating: "\r\nx", count: 20).utf8))
        #expect(Selection.isUnchanged(content, in: terminal.grid), "pushed into history: unchanged")
    }

    @Test(
        "a write, erase, insert or delete on the selected row drops it",
        arguments: [
            "z",  // a printed character
            "\u{1B}[2K",  // EL
            "\u{1B}[J",  // ED below
            "\u{1B}[L",  // IL
            "\u{1B}[M",  // DL
            "\u{1B}[@",  // ICH
            "\u{1B}[P",  // DCH
            "\u{1B}[X",  // ECH
        ])
    func rewritingDropsIt(sequence: String) {
        #expect(!onSelectedRow(sequence))
    }

    @Test("a rewrite followed by scrolling into history still drops it")
    func rewrittenThenScrolledDropsIt() {
        var (terminal, content) = selected()
        terminal.feed(Array("\u{1B}[3;1Hz\u{1B}[6;1H\r\nmore\r\nmore\r\nmore".utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid))
    }

    @Test("the same operations on another row keep it")
    func otherRowsKeepIt() {
        var (terminal, content) = selected()
        for sequence in ["z", "\u{1B}[2K", "\u{1B}[@", "\u{1B}[P", "\u{1B}[X"] {
            terminal.feed(Array("\u{1B}7\u{1B}[5;1H\(sequence)\u{1B}8".utf8))
        }
        #expect(Selection.isUnchanged(content, in: terminal.grid))
    }

    @Test("a scroll inside a region that holds the row drops it")
    func regionScrollDropsIt() {
        var (terminal, content) = selected()
        terminal.feed(Array("\u{1B}[2;5r\u{1B}[5;1H\n\u{1B}[r".utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid))
    }

    @Test("switching to the alternate screen drops it")
    func alternateScreenDropsIt() {
        var (terminal, content) = selected()
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid))
    }

    /// Ink's redraw, as Claude Code does it many times a second: up over the
    /// region, erase each line, write it again.
    @Test("an Ink-style redraw over the selected row drops it")
    func inkRedrawDropsIt() {
        var (terminal, content) = selected()
        var redraw = ""
        for _ in 0..<3 { redraw += "\u{1B}[1A\u{1B}[2K" }
        redraw += "\rone\r\ntwo\r\nthree"
        terminal.feed(Array(redraw.utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid))
    }

    @Test("rewriting the row with the same text keeps it")
    func identicalRewriteKeepsIt() {
        #expect(onSelectedRow("\u{1B}[2K6"))
    }

    @Test("a write in columns the selection does not cover keeps it")
    func otherColumnsKeepIt() {
        #expect(onSelectedRow("\u{1B}[3;12Hclock"))
    }

    @Test("output filling selected blank space keeps it; changing selected text does not")
    func blankSpaceFilledKeepsIt() {
        // A select-all: every live row, the blank ones below the cursor too.
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array("$ ".utf8))
        let all = SelectionRange(
            start: SelectionPoint(row: 0, column: 0), end: SelectionPoint(row: 5, column: 19))
        let content = Selection.content(of: all, in: terminal.grid)
        terminal.feed(Array("\r\n\r\nstreamed\r\nmore".utf8))
        #expect(Selection.isUnchanged(content, in: terminal.grid), "landed on selected blanks")
        terminal.feed(Array("\u{1B}[1;1Hrewritten".utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid), "rewrote the selected prompt")
    }

    @Test("clearing the history under a selection drops it")
    func clearedHistoryDropsIt() {
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array((0..<10).map { "\($0)" }.joined(separator: "\r\n").utf8))
        let range = SelectionRange(
            start: SelectionPoint(row: -2, column: 0), end: SelectionPoint(row: -1, column: 5))
        let content = Selection.content(of: range, in: terminal.grid)
        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(!Selection.isUnchanged(content, in: terminal.grid))
    }

    @Test("a selection wholly in history is never dropped by output")
    func historyOnlyIsKept() {
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array((0..<10).map { "\($0)" }.joined(separator: "\r\n").utf8))
        let range = SelectionRange(
            start: SelectionPoint(row: -2, column: 0), end: SelectionPoint(row: -1, column: 5))
        let content = Selection.content(of: range, in: terminal.grid)
        terminal.feed(Array("\u{1B}[2J\u{1B}[Hredrawn".utf8))
        #expect(Selection.isUnchanged(content, in: terminal.grid))
    }
}
