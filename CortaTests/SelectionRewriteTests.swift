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

import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// A pane drops its selection on the first frame after the program rewrites
/// a row under it, and keeps it while output only scrolls (#341).
@MainActor
struct SelectionRewriteTests {
    @Test func aRewrittenRowDropsTheSelectionAndScrollingDoesNot() {
        let pane = ViewController()
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array((0..<10).map { "\($0)" }.joined(separator: "\r\n").utf8))
        let range = SelectionRange(
            start: SelectionPoint(row: 2, column: 0), end: SelectionPoint(row: 2, column: 5))
        pane.selection = TerminalSelection(range, grid: terminal.grid)

        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil, "the first frame only records the rows")

        terminal.feed(Array("\r\nscrolled".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil, "scrolling keeps it on its text")

        // The selected text is now screen row 1 (line 2): erase it in place.
        terminal.feed(Array("\u{1B}7\u{1B}[2;1H\u{1B}[2K\u{1B}8".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection == nil)
    }

    @Test func aNewSelectionIsRecordedAfresh() {
        let pane = ViewController()
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array("a\r\nb\r\nc".utf8))
        let first = SelectionRange(
            start: SelectionPoint(row: 0, column: 0), end: SelectionPoint(row: 0, column: 1))
        pane.selection = TerminalSelection(first, grid: terminal.grid)
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        terminal.feed(Array("\u{1B}[1;1Hz".utf8))
        // Selected again after the rewrite: what is recorded is the new text.
        let second = SelectionRange(
            start: SelectionPoint(row: 0, column: 0), end: SelectionPoint(row: 0, column: 0))
        pane.selection = TerminalSelection(second, grid: terminal.grid)
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil)
    }
}
