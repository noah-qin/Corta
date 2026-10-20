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



extension Grid {
    // MARK: - Resizing

    /// A column change reflows (D03), except on the alternate screen: the
    /// program redraws on `SIGWINCH`, and re-wrapping would corrupt its model.
    /// A row-only change moves rows to or from scrollback.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        let newRows = min(max(1, newRows), Self.maxRows)
        let newColumns = min(max(1, newColumns), Self.maxColumns)
        guard newRows != rows || newColumns != columns else { return }

        // Exact cell coordinates a column change invalidates.
        if newColumns != columns {
            imagePlacements.removeAllPlacements()
        }

        if newColumns != columns, !isAlternateScreenActive {
            resizeTabStops(to: newColumns)
            reflow(toColumns: newColumns, newRows: newRows)
            rows = newRows
            resetScrollRegionAfterResize()
            return
        }

        if newRows < rows {
            // Off the top, into scrollback: the bottom holds the cursor and the
            // newest output, and truncating there loses the last commands silently.
            // Only enough rows to keep the cursor on screen; the rest are blank.
            let excess = rows - newRows
            let fromTop = min(excess, max(0, cursor.row - (newRows - 1)))
            for row in 0..<fromTop { scrollback.push(lines[row]) }
            if fromTop > 0 {
                lines.removeFirst(fromTop)
                cursor.row -= fromTop
            }
            let surplus = excess - fromTop
            if surplus > 0 { lines.removeLast(surplus) }
        } else if newRows > rows {
            lines.append(contentsOf: repeatElement(Line(), count: newRows - rows))
        }
        rows = newRows
        resizeTabStops(to: newColumns)
        if newColumns < columns {
            // Not reflowed, so cut: a row wider than the screen held cells
            // that selection, search and copy read but nothing showed.
            for row in 0..<lines.count { lines[row].truncate(toWidth: newColumns) }
        }
        columns = newColumns
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        pendingWrap = false
        resetScrollRegionAfterResize()
    }

    /// The whole new screen, as xterm does: a region set at the old size
    /// would otherwise stay there. Clamped instead, a window grown from 24
    /// rows kept scrolling at row 23 and stopped `CUD` there, so a program
    /// redrawing after `SIGWINCH` (Claude Code) stacked its footer on that
    /// row and left the rows below it blank. A program that wants a region
    /// at the new size sets it again.
    private mutating func resetScrollRegionAfterResize() {
        marginTop = 0
        marginBottom = rows - 1
    }

    // MARK: - Save and restore

    /// DECSC: cursor, pen, pending wrap and DECOM. No character sets.
    public mutating func saveCursor() {
        savedCursor = cursor
        savedPen = pen
        savedPendingWrap = pendingWrap
        savedOriginMode = originMode
    }

    /// DECRC; with nothing saved, home and the default rendition.
    public mutating func restoreCursor() {
        guard let savedCursor, let savedPen else {
            originMode = false
            moveCursor(row: 0, column: 0)
            pen.reset()
            return
        }
        moveCursor(row: savedCursor.row, column: savedCursor.column)
        pen = savedPen
        pendingWrap = savedPendingWrap
        originMode = savedOriginMode
    }

    // MARK: - Alternate screen

    /// `?1049` set: the main screen is parked whole in `suspendedMain`; the
    /// alternate screen is blank with no scrollback.
    public mutating func enterAlternateScreen() {
        saveCursor()
        guard suspendedMain == nil else {
            eraseDisplay(.all)
            marginTop = 0
            marginBottom = rows - 1
            moveCursor(row: 0, column: 0)
            return
        }
        suspendedMain = SuspendedScreen(self)
        lines = ScreenLines(repeating: Line(), count: rows)
        scrollback = Scrollback(limit: 0)
        graphemes = GraphemeTable()
        // One pane budget across both screens: the parked main screen keeps
        // its images, so the alternate screen gets only what they left —
        // a table of its own doubled what one hostile stream could retain.
        let parkedImages = imagePlacements
        imagePlacements = ImagePlacementTable()
        imagePlacements.maximumStoredBytes = max(
            0, parkedImages.maximumStoredBytes - parkedImages.storedBytes)
        marginTop = 0
        marginBottom = rows - 1
        isAlternateScreenActive = true
        moveCursor(row: 0, column: 0)
    }

    /// `?1049` reset. A resize meanwhile applies to the parked screen too.
    public mutating func exitAlternateScreen() {
        guard let suspended = suspendedMain else { return }
        suspendedMain = nil
        var main = suspended.grid
        main.cursorStyle = cursorStyle  // the style is global, not per screen
        main.cursorStyleIsExplicit = cursorStyleIsExplicit
        main.cellPixelHeight = cellPixelHeight  // a property of the window
        main.ambiguousIsWide = ambiguousIsWide  // a setting of the window
        main.cellPixelWidth = cellPixelWidth
        // Terminal-wide, not per screen: `self = main` would restore the old
        // value.
        main.reverseWraparoundEnabled = reverseWraparoundEnabled
        main.isCursorVisible = isCursorVisible
        main.autowrapEnabled = autowrapEnabled
        if main.rows != rows || main.columns != columns {
            main.resize(rows: rows, columns: columns)
        }
        self = main
        restoreCursor()
    }
}
