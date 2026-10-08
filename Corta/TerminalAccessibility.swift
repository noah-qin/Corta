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

/// A flattened copy of what a pane shows, indexed for AppKit's
/// accessibility questions in both directions (offset ↔ cell).
///
/// A snapshot, because VoiceOver asks a dozen questions per step: one copy
/// answers them consistently, never half-way through a parse batch.
/// The viewport only, at the current `scrollOffset`: an assistive
/// technology's text area is what is on screen, and history is reached by
/// scrolling, as for a sighted user.
struct TerminalAccessibilitySnapshot {
    let text: String
    /// The UTF-16 offset where each visible row begins, blank rows included.
    let lineStarts: [Int]
    /// Grid geometry, spoken in the element's help.
    let rows: Int
    let columns: Int
    let cursorRow: Int
    let cursorColumn: Int
    /// The insertion point.
    let cursorOffset: Int
    /// The selection clipped to the viewport; empty at the insertion point
    /// when none.
    let selectedRange: NSRange
    /// Document row `r` is visible row `r + scrollOffset`.
    let scrollOffset: Int

    /// Per visible row, character boundaries as (UTF-16 offset, column).
    ///
    /// The point of the type: UTF-16 units and columns agree only for ASCII.
    /// CJK is two columns and one unit, astral emoji two and two, combining
    /// marks zero columns and one or more units.
    private let rowBoundaries: [[(offset: Int, column: Int)]]
    /// Each row's UTF-16 length, for clamping past the trimmed tail.
    private let rowLengths: [Int]

    /// - Parameter scrollOffset: rows scrolled back; rows are read as document
    ///   rows, so the document-anchored `selection` indexes directly.
    init(grid: Grid, selection: SelectionRange?, scrollOffset: Int = 0) {
        var text = ""
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(grid.rows)
        var rowBoundaries: [[(offset: Int, column: Int)]] = []
        rowBoundaries.reserveCapacity(grid.rows)
        var rowLengths: [Int] = []
        rowLengths.reserveCapacity(grid.rows)

        for row in 0..<grid.rows {
            lineStarts.append(text.utf16.count)
            let (rowText, columns) = grid.rowTextWithColumns(row - scrollOffset)
            var boundaries: [(offset: Int, column: Int)] = []
            boundaries.reserveCapacity(columns.count)
            var utf16Offset = 0
            for (index, character) in rowText.enumerated() {
                if index < columns.count { boundaries.append((utf16Offset, columns[index])) }
                utf16Offset += character.utf16.count
            }
            rowBoundaries.append(boundaries)
            rowLengths.append(utf16Offset)
            text += rowText
            if row != grid.rows - 1 { text += "\n" }
        }

        self.text = text
        self.lineStarts = lineStarts
        self.rows = grid.rows
        self.columns = grid.columns
        self.cursorRow = grid.cursor.row
        self.cursorColumn = grid.cursor.column
        self.scrollOffset = scrollOffset
        self.rowBoundaries = rowBoundaries
        self.rowLengths = rowLengths

        // Stored properties aren't all set yet, so this calls the static rule.
        func offset(documentRow: Int, column: Int) -> Int {
            Self.offset(
                documentRow: documentRow, column: column, lineStarts: lineStarts,
                rowBoundaries: rowBoundaries, rowLengths: rowLengths,
                textLength: text.utf16.count, scrollOffset: scrollOffset)
        }

        self.cursorOffset = offset(documentRow: grid.cursor.row, column: grid.cursor.column)
        if let selection {
            // Both ends of a selection are cells it includes; an NSRange
            // ends after its last unit. The end is therefore the boundary
            // after the character in the last selected cell — a whole
            // grapheme, however many UTF-16 units or columns it takes.
            let lower = min(selection.start, selection.end)
            let upper = max(selection.start, selection.end)
            let start = offset(documentRow: lower.row, column: lower.column)
            let end = Self.offset(
                after: upper.column, documentRow: upper.row, lineStarts: lineStarts,
                rowBoundaries: rowBoundaries, rowLengths: rowLengths,
                textLength: text.utf16.count, scrollOffset: scrollOffset)
            self.selectedRange = NSRange(location: min(start, end), length: abs(end - start))
        } else {
            self.selectedRange = NSRange(location: cursorOffset, length: 0)
        }
    }

    /// Clamps to the viewport's ends and the row's trimmed tail, so an
    /// off-screen selection reports its visible part.
    private static func offset(
        documentRow: Int, column: Int, lineStarts: [Int],
        rowBoundaries: [[(offset: Int, column: Int)]], rowLengths: [Int],
        textLength: Int, scrollOffset: Int
    ) -> Int {
        let row = documentRow + scrollOffset
        guard row >= 0 else { return 0 }
        guard row < lineStarts.count else { return textLength }
        let start = lineStarts[row]
        if let exact = rowBoundaries[row].last(where: { $0.column <= column }) {
            return start + (exact.column == column ? exact.offset : rowLengths[row])
        }
        return start + min(rowLengths[row], max(0, column))
    }

    /// The offset just past the character in `column`: the next
    /// character's start, or the row's end when it is the last. A column
    /// past the trimmed tail ends at the row's end; rows off the viewport
    /// clamp to its ends.
    private static func offset(
        after column: Int, documentRow: Int, lineStarts: [Int],
        rowBoundaries: [[(offset: Int, column: Int)]], rowLengths: [Int],
        textLength: Int, scrollOffset: Int
    ) -> Int {
        let row = documentRow + scrollOffset
        guard row >= 0 else { return 0 }
        guard row < lineStarts.count else { return textLength }
        let start = lineStarts[row]
        let boundaries = rowBoundaries[row]
        guard let index = boundaries.lastIndex(where: { $0.column <= column }) else {
            return start + min(rowLengths[row], max(0, column + 1))
        }
        let next = index + 1 < boundaries.count ? boundaries[index + 1].offset : rowLengths[row]
        return start + next
    }

    // MARK: - The two conversions

    func offset(documentRow: Int, column: Int) -> Int {
        Self.offset(
            documentRow: documentRow, column: column, lineStarts: lineStarts,
            rowBoundaries: rowBoundaries, rowLengths: rowLengths,
            textLength: text.utf16.count, scrollOffset: scrollOffset)
    }

    /// The cell an offset falls in and its width in columns: one for ASCII
    /// and combining sequences, two for wide characters. Drawing a range
    /// needs the width, or it clips half a CJK character.
    func cellSpan(forOffset offset: Int) -> (row: Int, column: Int, columns: Int) {
        let cell = cell(forOffset: offset)
        guard row(cell.row) else { return (cell.row, cell.column, 1) }
        let boundaries = rowBoundaries[cell.row]
        guard let index = boundaries.lastIndex(where: { $0.column <= cell.column })
        else { return (cell.row, cell.column, 1) }
        let next = index + 1 < boundaries.count ? boundaries[index + 1].column : nil
        // Width is the gap to the next character; one at the row's end.
        let width = next.map { max(1, $0 - boundaries[index].column) } ?? 1
        return (cell.row, cell.column, width)
    }

    private func row(_ index: Int) -> Bool { index >= 0 && index < rowBoundaries.count }

    /// The visible row and column an offset falls in, never splitting a
    /// character; past a trimmed tail, the column the tail would reach.
    func cell(forOffset offset: Int) -> (row: Int, column: Int) {
        guard !lineStarts.isEmpty else { return (0, 0) }
        let clamped = min(max(0, offset), text.utf16.count)
        var row = 0
        for (index, start) in lineStarts.enumerated() where start <= clamped { row = index }
        let within = clamped - lineStarts[row]
        guard let boundary = rowBoundaries[row].last(where: { $0.offset <= within }) else {
            return (row, within)
        }
        // Past the tail: keep counting columns, so blanks still map.
        if within > rowLengths[row] - 1, within >= rowLengths[row] {
            return (row, boundary.column + (within - boundary.offset))
        }
        return (row, boundary.column)
    }
}
