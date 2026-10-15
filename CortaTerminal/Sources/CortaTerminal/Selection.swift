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

/// Text selection: the rules for what a click selects and what copy
/// puts on the clipboard.
///
/// The model lives in the core, not the shell, because two of its jobs are
/// defined by each line's `wrapped` flag, which is grid state the app layer
/// has no business reading (`DECISIONS.md` D03): copying a soft-wrapped line
/// must yield ONE line with no inserted newline, and triple-click selects a
/// logical line by following that flag.
///
/// Coordinates are *document* coordinates, never viewport rows: row ≥ 0 is a
/// live-screen row and row < 0 addresses the scrollback counting backwards
/// from the screen boundary (row -1 is the newest history line — the same
/// numbering `Grid.dump` prints). A selection therefore survives the user
/// scrolling the viewport, which only changes how the shell maps document
/// rows to screen rows. When output pushes `k` lines from the screen into
/// the scrollback, every stored row shifts by `-k`; the shell applies that
/// with `SelectionRange.shifted(byScrollbackGrowth:)`, so a selection stays
/// on its text while output scrolls underneath it.
///
/// Stateless, like the rest of the core: the shell owns the range it is
/// dragging and passes the grid in (`DECISIONS.md` D07 — no singletons).
/// Selection is not a hot path; this file allocates and builds `String`s.

/// One point in the terminal document. See the file header for the row
/// numbering. Columns are cells, not scalars — a wide character's spacer is
/// a column of its own, which is what a mouse can point at.
public struct SelectionPoint: Equatable, Comparable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (a: Self, b: Self) -> Bool {
        a.row != b.row ? a.row < b.row : a.column < b.column
    }
}

/// An inclusive range of the document, always in document order.
public struct SelectionRange: Equatable, Sendable {
    public var start: SelectionPoint
    public var end: SelectionPoint

    /// Normalizes, so a drag upwards or leftwards still yields `start <= end`.
    public init(anchor: SelectionPoint, head: SelectionPoint) {
        if head < anchor {
            start = head
            end = anchor
        } else {
            start = anchor
            end = head
        }
    }

    public init(start: SelectionPoint, end: SelectionPoint) {
        self.init(anchor: start, head: end)
    }

    /// Applies the shared row mapping to both ends, preserving columns.
    public func reanchored(from oldTotal: Int, to newTotal: Int) -> SelectionRange {
        SelectionRange(
            start: SelectionPoint(row: ScrollbackCoordinates.reanchoredRow(start.row, from: oldTotal, to: newTotal), column: start.column),
            end: SelectionPoint(row: ScrollbackCoordinates.reanchoredRow(end.row, from: oldTotal, to: newTotal), column: end.column))
    }

    /// Re-anchors after output pushed `growth` lines from the screen into
    /// the scrollback: the line that was live row `r` is now scrollback, and
    /// every document row counts one further from the screen boundary. The
    /// batched cousin of `ScrollbackCoordinates.reanchoredRow`, applied to
    /// both ends of a range at once — pass it the same
    /// `max(0, newTotal - oldTotal)` that function computes internally.
    public func shifted(byScrollbackGrowth growth: Int) -> SelectionRange {
        SelectionRange(
            start: SelectionPoint(row: start.row - growth, column: start.column),
            end: SelectionPoint(row: end.row - growth, column: end.column))
    }
}

/// What a click picks and a drag extends by. Double-click is a word,
/// triple-click a logical line.
public enum SelectionUnit: Equatable, Sendable {
    case character
    case word
    case logicalLine
}

/// Selection rules over a grid. All static; the name is the namespace.
public enum Selection {
    /// Word characters for double-click: letters, digits, and `_`, `-`, `.`,
    /// `/` — a path or a `key=value` pair selects as one word.
    public static func isWordScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:  // 0-9 A-Z a-z
            return true
        case 0x5F, 0x2D, 0x2E, 0x2F:  // _ - . /
            return true
        case let value where value < 0x80:
            return false
        default:
            guard let scalar = Unicode.Scalar(scalar) else { return false }
            let character = Character(scalar)
            return character.isLetter || character.isNumber
        }
    }

    /// The range one click at `point` selects: the cell itself, the word
    /// under it, or the whole logical line, following wraps.
    public static func range(
        at point: SelectionPoint, unit: SelectionUnit, in grid: Grid
    ) -> SelectionRange {
        switch unit {
        case .character:
            return SelectionRange(anchor: point, head: point)
        case .word:
            return wordRange(at: point, in: grid)
        case .logicalLine:
            return logicalLineRange(at: point, in: grid)
        }
    }

    /// The range a drag to `head` selects, keeping `anchor` fixed and
    /// honouring the gesture's unit: a word drag extends word by word from
    /// the anchor's word.
    public static func range(
        from anchor: SelectionPoint, to head: SelectionPoint, unit: SelectionUnit, in grid: Grid
    ) -> SelectionRange {
        switch unit {
        case .character:
            return SelectionRange(anchor: anchor, head: head)
        case .word:
            let anchorRange = wordRange(at: anchor, in: grid)
            let headRange = wordRange(at: head, in: grid)
            return SelectionRange(
                start: min(anchorRange.start, headRange.start),
                end: max(anchorRange.end, headRange.end))
        case .logicalLine:
            let anchorRange = logicalLineRange(at: anchor, in: grid)
            let headRange = logicalLineRange(at: head, in: grid)
            return SelectionRange(
                start: min(anchorRange.start, headRange.start),
                end: max(anchorRange.end, headRange.end))
        }
    }

    /// The selected text, as copy puts it on the clipboard.
    ///
    /// Two rules, both load-bearing (`DECISIONS.md` D03):
    ///
    /// - A row whose `wrapped` flag is set joins the next row with NO
    ///   newline — a soft-wrapped command copies as one line. A wrapped row
    ///   is full to the right margin by construction, so its trailing cells
    ///   are content and are kept verbatim.
    /// - Every other row (a hard line end, and the last selected row) has
    ///   trailing blanks trimmed.
    ///
    /// Wide-pair spacers contribute nothing — the pair's lead cell already
    /// produced the character — and a cell interning a grapheme cluster
    /// yields the whole cluster, so combining marks survive a copy.
    public static func text(of range: SelectionRange, in grid: Grid) -> String {
        guard range.start <= range.end else { return "" }
        var text = ""
        var row = range.start.row
        while row <= range.end.row {
            let line = line(at: row, in: grid)
            let firstColumn = row == range.start.row ? range.start.column : 0
            let lastColumn = row == range.end.row ? range.end.column : grid.columns - 1
            var rowText = ""
            var column = max(0, firstColumn)
            let upper = min(lastColumn, grid.columns - 1)
            while column <= upper {
                let cell = line[column]
                column += 1
                if cell.attributes.contains(.wideSpacer) { continue }
                if let cluster = grid.graphemes.scalars(for: cell.grapheme) {
                    for scalar in cluster {
                        if let scalar = Unicode.Scalar(scalar) {
                            rowText.unicodeScalars.append(scalar)
                        }
                    }
                } else if let scalar = Unicode.Scalar(cell.scalar) {
                    rowText.unicodeScalars.append(scalar)
                }
            }
            let continues = row != range.end.row && line.wrapped
            if !continues {
                while rowText.last == " " { rowText.removeLast() }
            }
            text += rowText
            if row != range.end.row, !continues { text += "\n" }
            row += 1
        }
        return text
    }

    // MARK: - Internals

    /// The document row's line: negative rows count backwards from the
    /// screen boundary into the scrollback, oldest-last. Out-of-range rows
    /// yield an empty line (a stale selection reads as blank, never traps).
    private static func line(at row: Int, in grid: Grid) -> Line {
        row < 0 ? grid.scrollback[grid.scrollback.count + row] : grid.line(row)
    }

    /// True when `row` continues the logical line begun on the row above it.
    private static func continues(fromAbove row: Int, in grid: Grid) -> Bool {
        line(at: row - 1, in: grid).wrapped
    }

    private static func scalar(at point: SelectionPoint, in grid: Grid) -> UInt32 {
        line(at: point.row, in: grid)[point.column].scalar
    }

    /// The word under `point`, expanded across soft-wrap boundaries in both
    /// directions. A click on a non-word character selects that one cell.
    private static func wordRange(at point: SelectionPoint, in grid: Grid) -> SelectionRange {
        guard isWordScalar(scalar(at: point, in: grid)) else {
            return SelectionRange(anchor: point, head: point)
        }
        var start = point
        while true {
            var left = SelectionPoint(row: start.row, column: start.column - 1)
            if left.column < 0 {
                guard continues(fromAbove: start.row, in: grid) else { break }
                left = SelectionPoint(row: start.row - 1, column: grid.columns - 1)
            }
            guard isWordScalar(scalar(at: left, in: grid)) else { break }
            start = left
        }
        var end = point
        while true {
            var right = SelectionPoint(row: end.row, column: end.column + 1)
            if right.column >= grid.columns {
                guard line(at: end.row, in: grid).wrapped, end.row < grid.rows - 1 else { break }
                right = SelectionPoint(row: end.row + 1, column: 0)
            }
            guard isWordScalar(scalar(at: right, in: grid)) else { break }
            end = right
        }
        return SelectionRange(start: start, end: end)
    }

    /// The logical line containing `point`: from the first row of the wrap
    /// chain, column 0, to the last row of the chain, full width.
    private static func logicalLineRange(at point: SelectionPoint, in grid: Grid) -> SelectionRange {
        var top = point.row
        while continues(fromAbove: top, in: grid) { top -= 1 }
        var bottom = point.row
        while bottom < grid.rows - 1, line(at: bottom, in: grid).wrapped { bottom += 1 }
        return SelectionRange(
            start: SelectionPoint(row: top, column: 0),
            end: SelectionPoint(row: bottom, column: grid.columns - 1))
    }
}

/// What the rows under a selection held when it was made, so the shell can
/// tell when the program rewrote the text it covers.
///
/// Output that *scrolls* keeps a selection on its text
/// (`SelectionRange.shifted(byScrollbackGrowth:)`). Output that *rewrites*
/// the selected text in place — a printed character, an erase, an insert or
/// delete, a region scroll, the alternate screen — leaves it naming text it
/// no longer covers, so it is dropped: a redraw such as Claude Code's (cursor
/// up, `CSI 2K`, write again) otherwise left a highlight lying across
/// whatever came next. Alacritty, xterm and URxvt drop a selection an erase
/// overlaps; this also drops one a write changes, which is what a redraw does.
///
/// Three things are not a rewrite. A row written with the same text — Ink
/// redraws every dynamic line each frame — or written only in columns the
/// selection does not cover. And selected *blank* space that output then
/// fills: streaming output landing on the empty rows a select-all covers
/// appends; it changes no text the selection named.
///
/// The per-row revisions damage tracking keeps (`Grid.lineRevision`), which
/// travel with their lines through a full-screen scroll, are the fast path:
/// an unchanged revision is unchanged text, and only a changed one reads
/// the cells.
public struct SelectionContent: Equatable, Sendable {
    let generation: UInt64
    let totalPushed: Int
    let range: SelectionRange
    let firstRow: Int
    let revisions: [UInt64]
    let texts: [String]
}

extension Selection {
    /// Records what `range` covers now, in the grid it was made against.
    public static func content(of range: SelectionRange, in grid: Grid) -> SelectionContent {
        let first = max(0, range.start.row)
        let last = min(grid.rows - 1, range.end.row)
        let rows = first <= last ? Array(first...last) : []
        return SelectionContent(
            generation: grid.linesGeneration,
            totalPushed: grid.scrollback.totalPushed,
            range: range,
            firstRow: first,
            revisions: rows.map { grid.lineRevision($0) },
            texts: rows.map { rowText(range, documentRow: $0, shift: 0, in: grid) })
    }

    /// Whether the text `content` recorded is still there: the same screen
    /// (not the alternate one, not a reflow), the selection's history not
    /// cleared or evicted, and no non-blank selected text rewritten, even
    /// when the same batch then pushes that row into history.
    public static func isUnchanged(_ content: SelectionContent, in grid: Grid) -> Bool {
        guard grid.linesGeneration == content.generation else { return false }
        let growth = max(0, grid.scrollback.totalPushed - content.totalPushed)
        // `CSI 3J` or the ring's limit took the top of it away.
        guard content.range.start.row - growth >= -grid.scrollback.count else { return false }
        for (offset, revision) in content.revisions.enumerated() {
            let recorded = content.firstRow + offset
            let row = recorded - growth
            guard row < grid.rows else { return false }
            guard !content.texts[offset].isEmpty else { continue }
            // A row can be rewritten and pushed into history in one batch.
            // History is immutable only after the push, so compare its text
            // too; only a still-live row has a revision fast path.
            if row >= 0, grid.lineRevision(row) == revision { continue }
            if rowText(content.range, documentRow: recorded, shift: growth, in: grid)
                != content.texts[offset]
            {
                return false
            }
        }
        return true
    }

    /// The selected columns of one row of `range`, which is in coordinates
    /// `shift` pushed lines old.
    private static func rowText(
        _ range: SelectionRange, documentRow: Int, shift: Int, in grid: Grid
    ) -> String {
        let row = documentRow - shift
        let start = documentRow == range.start.row ? range.start.column : 0
        let end = documentRow == range.end.row ? range.end.column : grid.columns - 1
        return text(
            of: SelectionRange(
                start: SelectionPoint(row: row, column: start), end: SelectionPoint(row: row, column: end)),
            in: grid)
    }
}
