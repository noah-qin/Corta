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

/// Reflow: re-wrapping the document when the column count changes.
///
/// The `wrapped` flag is the source of truth (`DECISIONS.md` D03): consecutive
/// rows joined by it are one logical line, and reflow re-wraps logical
/// lines at the new width. A logical line can span the scrollback/screen
/// boundary — a long wrapped command whose early rows already scrolled into
/// history while its tail is still on screen — so this operates on
/// scrollback and screen as one flattened document, not two independent
/// pieces, and only splits them back apart once every row has its new
/// width.
///
/// Not applied to the alternate screen: it has no scrollback, and a
/// full-screen application redraws itself on `SIGWINCH`, so re-wrapping
/// what it drew would corrupt its own model of the screen (`Grid.resize`
/// guards this — see its call site).
/// Where a reflow moved each row, for whatever holds absolute rows
/// (`totalPushed + screenRow`) outside the grid — command records, the
/// shell-integration state. A row maps to the row its first cell went to.
public struct RowRemap: Sendable, Equatable {
    /// Absolute row of the old document's first row (scrollback index 0).
    let oldBase: Int
    let newBase: Int
    /// Where each old row's first cell went, in new document rows and columns.
    let newRowOfOldRow: [Int]
    let newColumnOfOldRow: [Int]
    let newRowCount: Int
    let newColumns: Int

    public func map(_ absolute: Int) -> Int {
        let row = absolute - oldBase
        if row < 0 { return absolute + (newBase - oldBase) }
        if row >= newRowOfOldRow.count {
            return newBase + newRowCount + (row - newRowOfOldRow.count)
        }
        return newBase + newRowOfOldRow[row]
    }

    /// A prompt's end column after the reflow: kept only while it still lies
    /// on the prompt's own (mapped) row, which is what a prompt-end column
    /// means (`CommandRecord.promptEndColumn`).
    func promptEndColumn(promptRow: Int, column: Int) -> Int? {
        guard let position = mapPosition(row: promptRow, column: column),
            position.row == map(promptRow)
        else { return nil }
        return position.column
    }

    /// Where the cell at `column` of an old row went, when that is certain:
    /// the cells from the row's start to it still fit on one new row, so
    /// nothing between them wrapped. `nil` otherwise — a wide pair pushed
    /// to the next row would shift the count, and a guess is worse than
    /// none for what reads it (where a typed command starts).
    public func mapPosition(row absolute: Int, column: Int) -> (row: Int, column: Int)? {
        let row = absolute - oldBase
        guard row >= 0, row < newRowOfOldRow.count else { return (map(absolute), column) }
        let newColumn = newColumnOfOldRow[row] + column
        guard newColumn < newColumns else { return nil }
        return (newBase + newRowOfOldRow[row], newColumn)
    }
}

extension Grid {
    /// Re-wraps the whole document at `newColumns`, producing exactly
    /// `newRows` screen rows (padding with blanks if the reflowed document
    /// is shorter) and moving everything above that back into scrollback.
    /// The cursor keeps its logical position — the same character, not the
    /// same (row, column) — by tracking a cell index within its logical line
    /// through the rewrap rather than trying to translate coordinates
    /// directly. Past the line's last character it keeps its distance from
    /// it, and a pending wrap stays pending.
    mutating func reflow(toColumns newColumns: Int, newRows: Int) {
        guard newColumns > 0 else { return }
        let oldScrollbackCount = scrollback.count
        var oldRows = scrollback.lines
        oldRows.append(contentsOf: lines)
        guard !oldRows.isEmpty else {
            columns = newColumns
            lines = ScreenLines(repeating: Line(), count: newRows)
            return
        }

        let cursorOldRow = min(oldScrollbackCount + cursor.row, oldRows.count - 1)
        // A pending wrap sits after the last column's character, not on it.
        let rewrapped = Self.rewrap(
            oldRows, toColumns: newColumns, cursorRow: cursorOldRow,
            cursorColumn: cursor.column + (pendingWrap ? 1 : 0))
        let oldBase = scrollback.totalPushed - oldScrollbackCount

        // Mirrors the non-reflowing row-shrink rule below: push only as
        // many rows to scrollback as it takes to keep the cursor's row on
        // screen, and drop any further surplus (blank rows below it, kept
        // around only because the old row count was taller) from the
        // bottom rather than archiving it.
        let totalRows = rewrapped.rows.count
        let historyCount: Int
        if totalRows <= newRows {
            historyCount = 0
        } else {
            let excess = totalRows - newRows
            historyCount = min(excess, max(0, rewrapped.cursorRow - (newRows - 1)))
        }
        // Counting on, never back: anchors (a scroll position, a search
        // match, a selection) re-anchor by how far `totalPushed` grew. A
        // narrower reflow pushes more rows than there were; a wider one
        // fewer, and then the history's rows renumber as though the
        // difference had been evicted.
        let newTotalPushed = max(scrollback.totalPushed, oldBase + historyCount)
        let newBase = newTotalPushed - historyCount
        var newScrollback = Scrollback(limit: scrollback.limit, alreadyPushed: newBase)
        for index in 0..<historyCount { newScrollback.push(rewrapped.rows[index]) }
        rowRemaps.append(
            RowRemap(
                oldBase: oldBase, newBase: newBase,
                newRowOfOldRow: rewrapped.newStartOfOldRow.map(\.row),
                newColumnOfOldRow: rewrapped.newStartOfOldRow.map(\.column),
                newRowCount: totalRows, newColumns: newColumns))
        var newScreen = ContiguousArray(
            rewrapped.rows[historyCount..<min(historyCount + newRows, totalRows)])
        if newScreen.count < newRows {
            newScreen.append(contentsOf: repeatElement(Line(), count: newRows - newScreen.count))
        }

        scrollback = newScrollback
        lines = ScreenLines(newScreen)
        columns = newColumns

        let cursorScreenRow = rewrapped.cursorRow - historyCount
        cursor.row = min(max(0, cursorScreenRow), newRows - 1)
        cursor.column = min(max(0, rewrapped.cursorColumn), newColumns - 1)
        pendingWrap = rewrapped.cursorPendingWrap && autowrapEnabled
    }

    /// Rewraps `rows` — already known to obey the `wrapped`-chain
    /// convention — into rows of `newColumns` width, preserving cell
    /// content and attributes, one logical line (one wrap chain) at a time.
    /// Reports where the cell at (`cursorRow`, `cursorColumn`) of `rows`
    /// lands afterwards, in the same (row, column) numbering as the
    /// returned `rows`. The column may lie past the row's stored cells:
    /// a row keeps only up to its last written cell, and blanks are trimmed.
    ///
    /// Each old row's mark (OSC 133) moves to the new row holding that old
    /// row's first cell; where two land on one row, a prompt mark wins over
    /// an output-start one. `newStartOfOldRow` is where each old row's first
    /// cell went.
    private static func rewrap(
        _ rows: [Line], toColumns newColumns: Int, cursorRow oldCursorRow: Int, cursorColumn oldCursorColumn: Int
    ) -> (
        rows: [Line], cursorRow: Int, cursorColumn: Int, cursorPendingWrap: Bool,
        newStartOfOldRow: [(row: Int, column: Int)]
    ) {
        var result: [Line] = []
        result.reserveCapacity(rows.count)
        var newStartOfOldRow: [(row: Int, column: Int)] = []
        newStartOfOldRow.reserveCapacity(rows.count)
        var cursorRow = 0
        var cursorColumn = 0
        var cursorPendingWrap = false

        var index = 0
        // Reuse scratch storage across logical lines instead of allocating
        // two arrays for each of hundreds of thousands of history lines.
        var cells: [Cell] = []
        var rowStarts: [Int] = []
        while index < rows.count {
            let chainStart = index
            cells.removeAll(keepingCapacity: true)
            rowStarts.removeAll(keepingCapacity: true)
            while true {
                let line = rows[index]
                rowStarts.append(cells.count)
                cells.append(contentsOf: line.cells)
                let isLast = !line.wrapped || index == rows.count - 1
                index += 1
                if isLast { break }
            }
            while let last = cells.last, last.isBlank { cells.removeLast() }

            // The chain holding the cursor's row claims it, by row rather
            // than by cell count: the cursor may sit on blanks a row never
            // stored, past every cell the chain has.
            let target: Int? =
                (chainStart..<index).contains(oldCursorRow)
                ? rowStarts[oldCursorRow - chainStart] + oldCursorColumn : nil

            var wrapped = wrapCells(cells, toColumns: newColumns, cursorAt: target, rowStarts: rowStarts)
            if target != nil {
                cursorRow = result.count + wrapped.cursorRow
                cursorColumn = wrapped.cursorColumn
                cursorPendingWrap = wrapped.cursorPendingWrap
            }
            for (offset, start) in wrapped.rowOfStart.enumerated() {
                let newRow = start.row
                newStartOfOldRow.append((result.count + newRow, start.column))
                let mark = rows[chainStart + offset].mark
                guard mark != .none else { continue }
                let existing = wrapped.rows[newRow].mark
                if existing == .none || (mark.isPrompt && !existing.isPrompt) {
                    wrapped.rows[newRow].mark = mark
                }
            }
            result.append(contentsOf: wrapped.rows)
        }
        return (result, cursorRow, cursorColumn, cursorPendingWrap, newStartOfOldRow)
    }

    /// Packs one logical line's cells into rows of `newColumns` width,
    /// never splitting a wide pair across rows — the same rule `writeWide`
    /// applies when it first produces a pair, replicated here so a re-wrap
    /// doesn't tear one apart.
    /// `rowStarts` are cell indices, ascending; `rowOfStart` gives the row and
    /// column each lands at — one past the last cell (trimmed blanks) is
    /// where the last row ends.
    ///
    /// A `targetIndex` past the last cell is that many blanks after it, laid
    /// out as though they were cells and kept on the last row, clamped to
    /// its margin. Exactly at the margin it is a pending wrap: the next
    /// character continues the line on a new row, as it would have before.
    private static func wrapCells(
        _ cells: [Cell], toColumns newColumns: Int, cursorAt targetIndex: Int?, rowStarts: [Int]
    ) -> (
        rows: [Line], cursorRow: Int, cursorColumn: Int, cursorPendingWrap: Bool,
        rowOfStart: [(row: Int, column: Int)]
    ) {
        var rows: [Line] = []
        var current = Line()
        current.reserveCapacity(min(newColumns, cells.count))
        var column = 0
        var cursorRow = 0
        var cursorColumn = 0
        var rowOfStart: [(row: Int, column: Int)] = []
        rowOfStart.reserveCapacity(rowStarts.count)

        func record(_ cellIndex: Int) {
            while rowOfStart.count < rowStarts.count, rowStarts[rowOfStart.count] <= cellIndex {
                rowOfStart.append((rows.count, column))
            }
            guard let targetIndex, cellIndex == targetIndex else { return }
            cursorRow = rows.count
            cursorColumn = column
        }

        if cells.isEmpty {
            // Rows of blanks trimmed to nothing: every start is this one row.
            while rowOfStart.count < rowStarts.count { rowOfStart.append((0, 0)) }
            let blanks = targetIndex ?? 0
            return (
                [Line()], 0, min(blanks, newColumns - 1), blanks >= newColumns,
                rowOfStart
            )
        }

        var i = 0
        while i < cells.count {
            let cell = cells[i]
            // A lead whose spacer is missing is drawn narrow rather than read
            // past: the grid never writes one, but a reflow must not trust
            // that, since an out-of-range read here takes the app down.
            let hasSpacer = i + 1 < cells.count && cells[i + 1].attributes.contains(.wideSpacer)
            let width = cell.attributes.contains(.wide) && hasSpacer ? 2 : 1
            if width > newColumns || (width == 1 && cell.attributes.contains(.wide)) {
                // Degenerate: a pair that could never fit even alone (a
                // 1-column grid), or an orphaned lead. Demote to narrow
                // rather than loop forever.
                var demoted = cell
                demoted.attributes.remove(.wide)
                if column >= newColumns {
                    current.wrapped = true
                    rows.append(current)
                    current = Line()
                    current.reserveCapacity(min(newColumns, cells.count - i))
                    column = 0
                }
                record(i)
                current[column] = demoted
                column += 1
                i += hasSpacer ? 2 : 1
                continue
            }
            if column + width > newColumns {
                current.wrapped = true
                rows.append(current)
                current = Line()
                current.reserveCapacity(min(newColumns, cells.count - i))
                column = 0
            }
            record(i)
            current[column] = cell
            if width == 2 {
                current[column + 1] = cells[i + 1]
            }
            column += width
            i += width
        }
        rows.append(current)
        while rowOfStart.count < rowStarts.count { rowOfStart.append((rows.count - 1, column)) }

        var cursorPendingWrap = false
        if let targetIndex, targetIndex >= cells.count {
            let target = column + (targetIndex - cells.count)
            cursorRow = rows.count - 1
            cursorColumn = min(target, newColumns - 1)
            cursorPendingWrap = target >= newColumns
        }
        return (rows, cursorRow, cursorColumn, cursorPendingWrap, rowOfStart)
    }
}
