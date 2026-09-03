/// Reflow (M4.2): re-wrapping the document when the column count changes.
///
/// The `wrapped` flag is the source of truth (`DESIGN.md` §2.1): consecutive
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
        var newScrollback = Scrollback(limit: scrollback.limit)
        for index in 0..<historyCount { newScrollback.push(rewrapped.rows[index]) }
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
    private static func rewrap(
        _ rows: [Line], toColumns newColumns: Int, trackingOffset: Int
    ) -> (rows: [Line], cursorRow: Int, cursorColumn: Int) {
        var result: [Line] = []
        result.reserveCapacity(rows.count)
        var cursorRow = 0
        var cursorColumn = 0

        var index = 0
        var globalOffset = 0
        var foundTarget = false
        while index < rows.count {
            let chainStart = index
            var cells: [Cell] = []
            while true {
                let line = rows[index]
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

            let wrapped = wrapCells(cells, toColumns: newColumns, cursorAt: target)
            if target != nil {
                cursorRow = result.count + wrapped.cursorRow
                cursorColumn = wrapped.cursorColumn
            }
            result.append(contentsOf: wrapped.rows)
            _ = chainStart
            globalOffset += chainRawCount
        }
        return (result, cursorRow, cursorColumn)
    }

    /// Packs one logical line's cells into rows of `newColumns` width,
    /// never splitting a wide pair across rows — the same rule `writeWide`
    /// applies when it first produces a pair, replicated here so a re-wrap
    /// doesn't tear one apart.
    private static func wrapCells(
        _ cells: [Cell], toColumns newColumns: Int, cursorAt targetIndex: Int?
    ) -> (rows: [Line], cursorRow: Int, cursorColumn: Int) {
        var rows: [Line] = []
        var current = Line()
        var column = 0
        var cursorRow = 0
        var cursorColumn = 0

        func record(_ cellIndex: Int) {
            guard let targetIndex, cellIndex == targetIndex else { return }
            cursorRow = rows.count
            cursorColumn = column
        }

        if cells.isEmpty {
            record(0)
            return ([Line()], cursorRow, cursorColumn)
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
        return (rows, cursorRow, cursorColumn)
    }
}
