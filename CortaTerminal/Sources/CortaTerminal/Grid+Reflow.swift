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
    let newRowOfOldRow: [Int]
    let newRowCount: Int

    public func map(_ absolute: Int) -> Int {
        let row = absolute - oldBase
        if row < 0 { return absolute + (newBase - oldBase) }
        if row >= newRowOfOldRow.count {
            return newBase + newRowCount + (row - newRowOfOldRow.count)
        }
        return newBase + newRowOfOldRow[row]
    }
}

extension Grid {
    /// Re-wraps the whole document at `newColumns`, producing exactly
    /// `newRows` screen rows (padding with blanks if the reflowed document
    /// is shorter) and moving everything above that back into scrollback.
    /// The cursor keeps its logical position — the same character, not the
    /// same (row, column) — by tracking a cell offset through the rewrap
    /// rather than trying to translate coordinates directly.
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
        let cursorOffset = Self.documentCellOffset(ofRow: cursorOldRow, column: cursor.column, in: oldRows)

        let rewrapped = Self.rewrap(oldRows, toColumns: newColumns, trackingOffset: cursorOffset)
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
                newRowOfOldRow: rewrapped.newRowOfOldRow, newRowCount: totalRows))
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
        pendingWrap = false
    }

    /// How many cells precede (`row`, `column`) in the flattened document —
    /// not just within its own wrap chain, since `rewrap` below walks the
    /// whole document in one pass and needs one consistent coordinate space.
    private static func documentCellOffset(ofRow row: Int, column: Int, in rows: [Line]) -> Int {
        var offset = 0
        for index in 0..<row { offset += rows[index].count }
        offset += min(column, rows[row].count)
        return offset
    }

    /// Rewraps `rows` — already known to obey the `wrapped`-chain
    /// convention — into rows of `newColumns` width, preserving cell
    /// content and attributes, one logical line (one wrap chain) at a time.
    /// Reports where `trackingOffset` cells into the flattened document
    /// lands afterwards, in the same (row, column) numbering as the
    /// returned `rows`.
    ///
    /// Each old row's mark (OSC 133) moves to the new row holding that old
    /// row's first cell; where two land on one row, a prompt mark wins over
    /// an output-start one. `newRowOfOldRow` is that row for every old row.
    private static func rewrap(
        _ rows: [Line], toColumns newColumns: Int, trackingOffset: Int
    ) -> (rows: [Line], cursorRow: Int, cursorColumn: Int, newRowOfOldRow: [Int]) {
        var result: [Line] = []
        result.reserveCapacity(rows.count)
        var newRowOfOldRow: [Int] = []
        newRowOfOldRow.reserveCapacity(rows.count)
        var cursorRow = 0
        var cursorColumn = 0

        var index = 0
        var globalOffset = 0
        var foundTarget = false
        while index < rows.count {
            let chainStart = index
            var cells: [Cell] = []
            var rowStarts: [Int] = []
            while true {
                let line = rows[index]
                rowStarts.append(cells.count)
                cells.append(contentsOf: line.cells)
                let isLast = !line.wrapped || index == rows.count - 1
                index += 1
                if isLast { break }
            }
            let chainRawCount = cells.count
            while let last = cells.last, last.isBlank { cells.removeLast() }

            // Does the tracked offset fall in this chain? Use the raw
            // (pre-trim) count, matching how `documentCellOffset` measured
            // it — a trimmed trailing blank the cursor sat on clamps to the
            // last real character instead of falling in the next chain. The
            // upper bound is inclusive (an offset can sit exactly one past
            // a chain's last cell — the cursor resting right after the last
            // character typed on that logical line) and the first chain
            // that claims an offset wins, so a boundary value that is also
            // the *next* chain's lower bound doesn't get reassigned there.
            let target: Int?
            if !foundTarget, trackingOffset >= globalOffset, trackingOffset <= globalOffset + chainRawCount {
                target = min(trackingOffset - globalOffset, cells.count)
                foundTarget = true
            } else {
                target = nil
            }

            var wrapped = wrapCells(cells, toColumns: newColumns, cursorAt: target, rowStarts: rowStarts)
            if target != nil {
                cursorRow = result.count + wrapped.cursorRow
                cursorColumn = wrapped.cursorColumn
            }
            for (offset, newRow) in wrapped.rowOfStart.enumerated() {
                newRowOfOldRow.append(result.count + newRow)
                let mark = rows[chainStart + offset].mark
                guard mark != .none else { continue }
                let existing = wrapped.rows[newRow].mark
                if existing == .none || (mark.isPrompt && !existing.isPrompt) {
                    wrapped.rows[newRow].mark = mark
                }
            }
            result.append(contentsOf: wrapped.rows)
            globalOffset += chainRawCount
        }
        return (result, cursorRow, cursorColumn, newRowOfOldRow)
    }

    /// Packs one logical line's cells into rows of `newColumns` width,
    /// never splitting a wide pair across rows — the same rule `writeWide`
    /// applies when it first produces a pair, replicated here so a re-wrap
    /// doesn't tear one apart.
    /// `rowStarts` are cell indices, ascending; `rowOfStart` gives the row
    /// each lands in — one past the last cell (trimmed blanks) is the last row.
    private static func wrapCells(
        _ cells: [Cell], toColumns newColumns: Int, cursorAt targetIndex: Int?, rowStarts: [Int]
    ) -> (rows: [Line], cursorRow: Int, cursorColumn: Int, rowOfStart: [Int]) {
        var rows: [Line] = []
        var current = Line()
        var column = 0
        var cursorRow = 0
        var cursorColumn = 0
        var rowOfStart: [Int] = []
        rowOfStart.reserveCapacity(rowStarts.count)

        func record(_ cellIndex: Int) {
            while rowOfStart.count < rowStarts.count, rowStarts[rowOfStart.count] <= cellIndex {
                rowOfStart.append(rows.count)
            }
            guard let targetIndex, cellIndex == targetIndex else { return }
            cursorRow = rows.count
            cursorColumn = column
        }

        if cells.isEmpty {
            record(0)
            return ([Line()], cursorRow, cursorColumn, rowOfStart)
        }

        var i = 0
        while i < cells.count {
            let cell = cells[i]
            let width = cell.attributes.contains(.wide) ? 2 : 1
            if width > newColumns {
                // Degenerate: a pair that could never fit even alone (a
                // 1-column grid). Demote to narrow rather than loop forever.
                var demoted = cell
                demoted.attributes.remove(.wide)
                if column >= newColumns {
                    current.wrapped = true
                    rows.append(current)
                    current = Line()
                    column = 0
                }
                record(i)
                current[column] = demoted
                column += 1
                i += 2
                continue
            }
            if column + width > newColumns {
                current.wrapped = true
                rows.append(current)
                current = Line()
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
        while rowOfStart.count < rowStarts.count { rowOfStart.append(rows.count - 1) }

        if let targetIndex, targetIndex >= cells.count {
            if column >= newColumns {
                rows.append(Line())
                cursorRow = rows.count - 1
                cursorColumn = 0
            } else {
                cursorRow = rows.count - 1
                cursorColumn = column
            }
        }
        return (rows, cursorRow, cursorColumn, rowOfStart)
    }
}
