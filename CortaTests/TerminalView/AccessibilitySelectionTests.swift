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

/// `AXSetSelectedTextRange`: what an assistive technology's own text-selection
/// command does to a pane.
///
/// The client's range counts UTF-16 units in the value `accessibilityValue`
/// reports; the core selects document cells (D06). These tests drive the view's
/// real override from a real `Terminal`, and read the result through the same
/// `Selection.text` the copy command is injected with — so what is asserted is
/// what ⌘C would put on the clipboard.
@MainActor
struct AccessibilitySelectionSetterTests {
    private static func terminal(_ rows: Int = 4, _ columns: Int = 20) -> Terminal {
        Terminal(rows: rows, columns: columns, scrollbackLimit: 100)
    }

    private static func snapshot(
        _ terminal: Terminal, selection: SelectionRange? = nil, scrollOffset: Int = 0
    ) -> TerminalAccessibilitySnapshot {
        TerminalAccessibilitySnapshot(
            grid: terminal.grid, selection: selection, scrollOffset: scrollOffset)
    }

    /// A view whose setter writes into a recorder. The pane's real closure is
    /// three lines in `PanePointer.install`; this is the mapping and the
    /// validation the setter is responsible for.
    private static func settable(
        _ terminal: Terminal, selection: SelectionRange? = nil, scrollOffset: Int = 0
    ) -> (view: TerminalView, applied: () -> [TerminalSelection?]) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let grid = terminal.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(
                grid: grid, selection: selection, scrollOffset: scrollOffset)
        }
        var applied: [TerminalSelection?] = []
        view.onAccessibilitySetSelection = { applied.append($0) }
        return (view, { applied })
    }

    /// What ⌘C puts on the clipboard for a recorded selection, through the same
    /// function `PaneCommands` is injected with.
    private static func copied(_ applied: TerminalSelection?, in terminal: Terminal) -> String? {
        guard let range = Self.range(of: applied) else { return nil }
        return PaneCommands().buildSelectionText(range, terminal.grid)
    }

    /// The document range a recorded selection names. These tests do not scroll
    /// between the snapshot and the set, so its rows need no re-anchoring.
    private static func range(of applied: TerminalSelection?) -> SelectionRange? {
        guard let applied else { return nil }
        return SelectionRange(
            start: SelectionPoint(row: applied.start.row, column: applied.start.column),
            end: SelectionPoint(row: applied.end.row, column: applied.end.column))
    }

    /// The plain case: the range is UTF-16 offsets, the recorded selection is
    /// document cells, and copy puts exactly those characters on the clipboard.
    @Test func settingARangeSelectsExactlyThoseCharacters() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello world".utf8))
        let (view, applied) = Self.settable(terminal)
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 5))

        let recorded = applied()
        #expect(recorded.count == 1)
        #expect(recorded.first.flatMap { $0 }?.baseScrollbackTotal == 0)
        // The last selected character is "d" in column 10, the cell before the
        // selection's exclusive UTF-16 end.
        #expect(
            Self.range(of: recorded.first ?? nil)
                == SelectionRange(
                    start: SelectionPoint(row: 0, column: 6),
                    end: SelectionPoint(row: 0, column: 10)))
        #expect(Self.copied(recorded.first ?? nil, in: terminal) == "world")
        // The inverse subscription agrees: a snapshot of the new selection
        // reports the range the client set.
        let selection = SelectionRange(
            start: SelectionPoint(row: 0, column: 6), end: SelectionPoint(row: 0, column: 10))
        #expect(Self.snapshot(terminal, selection: selection).selectedRange == NSRange(location: 6, length: 5))
    }

    /// A wide character is one UTF-16 unit but two columns, so an offset inside
    /// it belongs to the whole character; the recorded cells span both columns.
    @Test func settingARangeAcrossWideCharactersSelectsWholeCharacters() {
        var terminal = Self.terminal()
        terminal.feed(Array("中文测试".utf8))
        let (view, applied) = Self.settable(terminal)
        // "文测": UTF-16 units 1...2, columns 2...5 (the last character's second
        // column is part of the selection, or its highlight is half a glyph).
        view.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 2))

        let recorded = applied()
        #expect(
            Self.range(of: recorded.first ?? nil)
                == SelectionRange(
                    start: SelectionPoint(row: 0, column: 2),
                    end: SelectionPoint(row: 0, column: 5)))
        #expect(Self.copied(recorded.first ?? nil, in: terminal) == "文测")
    }

    /// A combining mark adds UTF-16 units but no column, so a range that ends
    /// inside the sequence still selects the whole character — half a grapheme
    /// is not a place a text selection can end.
    @Test func settingARangeAcrossACombiningMarkSelectsTheWholeCharacter() {
        var terminal = Self.terminal()
        terminal.feed(Array("e\u{301}x".utf8))
        let (view, applied) = Self.settable(terminal)
        // Both the grapheme's two units and only its first snap to one cell.
        for range in [NSRange(location: 0, length: 2), NSRange(location: 0, length: 1)] {
            view.setAccessibilitySelectedTextRange(range)
        }

        let recorded = applied()
        #expect(recorded.count == 2)
        #expect(Self.copied(recorded[0], in: terminal) == "e\u{301}")
        #expect(Self.copied(recorded[1], in: terminal) == "e\u{301}")
    }

    /// A wrapped line is two rows of cells but one logical line. The range
    /// names cells across the wrap, and copy joins them by D03's rule — no
    /// newline between soft-wrapped rows — while the inverse subscription still
    /// reports the range the client set.
    @Test func settingARangeAcrossAWrappedLineSelectsTheWrappedText() {
        var terminal = Self.terminal(3, 8)
        terminal.feed(Array("0123456789".utf8))
        let (view, applied) = Self.settable(terminal)
        // Offsets 6...9 are "67", the line separator, and "8".
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 4))

        let recorded = applied()
        #expect(
            Self.range(of: recorded.first ?? nil)
                == SelectionRange(
                    start: SelectionPoint(row: 0, column: 6),
                    end: SelectionPoint(row: 1, column: 0)))
        #expect(Self.copied(recorded.first ?? nil, in: terminal) == "678")
        let selection = SelectionRange(
            start: SelectionPoint(row: 0, column: 6), end: SelectionPoint(row: 1, column: 0))
        #expect(Self.snapshot(terminal, selection: selection).selectedRange == NSRange(location: 6, length: 4))
    }

    /// A range edge on a row's line separator stays on that row, not spilling
    /// into the next line's first cell.
    @Test func aRangeEdgeOnALineSeparatorStaysOnItsRow() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello world".utf8))
        let (view, applied) = Self.settable(terminal)
        // The range includes the newline after row 0.
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 6))

        let recorded = applied()
        #expect(
            Self.range(of: recorded.first ?? nil)
                == SelectionRange(
                    start: SelectionPoint(row: 0, column: 6),
                    end: SelectionPoint(row: 0, column: 11)))
        #expect(Self.copied(recorded.first ?? nil, in: terminal) == "world")
    }

    /// Scrolled into history, the viewport's offsets are document rows below
    /// zero — the setter maps them to the history the client can see.
    @Test func settingARangeInScrolledHistoryRecordsDocumentRows() {
        var terminal = Self.terminal(3, 20)
        for index in 0..<8 { terminal.feed(Array("line\(index)\r\n".utf8)) }
        let snapshot = Self.snapshot(terminal, scrollOffset: 2)
        let (view, applied) = Self.settable(terminal, scrollOffset: 2)
        view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 5))

        let recorded = applied()
        #expect(Self.range(of: recorded.first ?? nil)?.start.row == -2)
        #expect(Self.copied(recorded.first ?? nil, in: terminal) == String(snapshot.text.prefix(5)))
    }

    /// A zero-length range clears the selection. The insertion point does not
    /// move: the cursor is the child's, and typing at a prompt belongs to the
    /// shell.
    @Test func aZeroLengthRangeClearsWithoutMovingTheCursor() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let cursorBefore = terminal.grid.cursor
        let (view, applied) = Self.settable(terminal)
        view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 5))
        view.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 0))

        let recorded = applied()
        #expect(recorded.count == 2)
        #expect(recorded[0] != nil)
        #expect(recorded[1] == nil)
        #expect(terminal.grid.cursor == cursorBefore)
    }

    /// Past the end is a client naming text this viewport does not have; it is
    /// ignored rather than clamped onto the nearest text. The integer extremes
    /// must not trap the arithmetic.
    @Test func outOfRangeRangesAreIgnoredWithoutACrash() {
        var terminal = Self.terminal()
        terminal.feed(Array("hello".utf8))
        let (view, applied) = Self.settable(terminal)
        let length = Self.snapshot(terminal).text.utf16.count
        let ranges = [
            NSRange(location: length + 1, length: 0),  // empty, past the last offset
            NSRange(location: 0, length: length + 1),  // overlong
            NSRange(location: length, length: 1),  // starts at the end, asks for one
            NSRange(location: -1, length: 1),
            NSRange(location: 0, length: -1),
            NSRange(location: Int.max, length: 0),
            NSRange(location: 1, length: Int.max),
        ]
        for range in ranges {
            view.setAccessibilitySelectedTextRange(range)
        }
        #expect(applied().isEmpty)
    }

    /// A range computed from text the pane has since replaced is stale: the
    /// fresh snapshot no longer covers it, so it is ignored instead of being
    /// applied to whatever now sits at those offsets.
    @Test func aRangeThatNoLongerFitsTheCurrentTextIsIgnored() {
        var long = Self.terminal()
        long.feed(Array("hello world".utf8))
        let (view, applied) = Self.settable(long)
        // The client reads, then the program rewrites the screen shorter.
        _ = view.accessibilitySelectedText()
        var short = Self.terminal()
        short.feed(Array("hi".utf8))
        let shortGrid = short.grid
        view.accessibilitySnapshotProvider = {
            TerminalAccessibilitySnapshot(grid: shortGrid, selection: nil)
        }
        view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 5))
        #expect(applied().isEmpty)
    }
}
