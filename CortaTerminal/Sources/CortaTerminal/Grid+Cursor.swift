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
    // MARK: - Cursor movement

    /// Zero-based and clamped.
    public mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(0, row), rows - 1)
        cursor.column = min(max(0, column), columns - 1)
        pendingWrap = false
    }

    public mutating func moveCursorUp(_ count: Int = 1) {
        let floor = (marginTop...marginBottom).contains(cursor.row) ? marginTop : 0
        moveCursor(row: max(floor, cursor.row - max(0, count)), column: cursor.column)
    }

    public mutating func moveCursorDown(_ count: Int = 1) {
        let ceiling = (marginTop...marginBottom).contains(cursor.row) ? marginBottom : rows - 1
        moveCursor(row: min(ceiling, cursor.row + max(0, count)), column: cursor.column)
    }

    /// Clamps at column 0 unless `?45` lets it cross auto-wrapped rows.
    public mutating func moveCursorLeft(_ count: Int = 1) {
        guard reverseWraparoundEnabled else {
            moveCursor(row: cursor.row, column: cursor.column - max(0, count))
            return
        }
        var remaining = max(0, count)
        while remaining > 0 {
            if cursor.column > 0 {
                cursor.column -= 1
                remaining -= 1
            } else if cursor.row > 0, lines[cursor.row - 1].wrapped {
                cursor.row -= 1
                cursor.column = columns - 1
                remaining -= 1
            } else {
                break
            }
        }
        pendingWrap = false
    }

    public mutating func moveCursorRight(_ count: Int = 1) {
        moveCursor(row: cursor.row, column: cursor.column + max(0, count))
    }

    /// CNL: CUD's movement, scroll region included, then column 0.
    public mutating func moveToNextLine(_ count: Int = 1) {
        moveCursorDown(max(1, count))
        carriageReturn()
    }

    /// CPL: CUU's movement, scroll region included, then column 0.
    public mutating func moveToPreviousLine(_ count: Int = 1) {
        moveCursorUp(max(1, count))
        carriageReturn()
    }

    /// CUP, HVP and VPA: zero-based, and under DECOM relative to the scroll
    /// region and confined to it. `moveCursor` is the screen-absolute move
    /// everything else (DECRC, reflow, images) means.
    public mutating func moveCursorAddressed(row: Int, column: Int) {
        guard originMode else {
            moveCursor(row: row, column: column)
            return
        }
        moveCursor(row: min(marginTop + max(0, row), marginBottom), column: column)
    }

    /// DECOM set or reset; either homes the cursor to the new origin.
    public mutating func setOriginMode(_ enabled: Bool) {
        originMode = enabled
        moveCursorAddressed(row: 0, column: 0)
    }

    /// The row a position report (CPR, DECXCPR) gives, one-based: counted
    /// from the region's top under DECOM, as the program addresses it.
    public var reportedCursorRow: Int {
        cursor.row - (originMode ? marginTop : 0) + 1
    }

    public mutating func carriageReturn() {
        cursor.column = 0
        pendingWrap = false
    }

    /// Like CUB by one. Out of an armed wrap it disarms rather than moves, which
    /// keeps `printf 'x%80s'; printf '\b'` on the row.
    public mutating func backspace() {
        if pendingWrap {
            pendingWrap = false
            return
        }
        if cursor.column > 0 {
            cursor.column -= 1
        } else if reverseWraparoundEnabled, cursor.row > 0, lines[cursor.row - 1].wrapped {
            cursor.row -= 1
            cursor.column = columns - 1
        }
    }

    /// HT — the next tab stop. Stops start every eight columns; HTS and TBC
    /// change them (`setTabStop`, `clearTabStop`).
    public mutating func tab() {
        tabForward(1)
    }

    public mutating func tabForward(_ count: Int) {
        for _ in 0..<max(1, count) {
            // Once at the margin, further tabs cannot change the cursor.
            guard cursor.column < columns - 1 else { break }
            var next = cursor.column + 1
            while next < columns - 1, !tabStops[next] { next += 1 }
            cursor.column = min(next, columns - 1)
        }
        pendingWrap = false
    }

    public mutating func tabBackward(_ count: Int) {
        for _ in 0..<max(1, count) {
            guard cursor.column > 0 else { break }
            var previous = cursor.column - 1
            while previous > 0, !tabStops[previous] { previous -= 1 }
            cursor.column = max(previous, 0)
        }
        pendingWrap = false
    }

    public static let tabInterval = 8

    public mutating func resetToInitialState() {
        let cellPixelHeight = cellPixelHeight
        let cellPixelWidth = cellPixelWidth
        self = Grid(rows: rows, columns: columns, scrollbackLimit: scrollback.limit)
        self.cellPixelHeight = cellPixelHeight
        self.cellPixelWidth = cellPixelWidth
    }

    /// Erases the screen and homes the cursor, keeping the scrollback. Not
    /// `ED 2` alone (the cursor stays mid-screen) and not a scroll into history
    /// (which makes "clear" and "keep history" the same thing).
    public mutating func clearScreen() {
        eraseDisplay(.all)
        cursor = Cursor(row: 0, column: 0)
        pendingWrap = false
    }

    var hasCompressionWork: Bool {
        scrollback.hasCompressionWork || suspendedMain?.grid.scrollback.hasCompressionWork == true
    }
    func nextCompressionWork() -> Scrollback.CompressionWork? {
        scrollback.nextCompressionWork() ?? suspendedMain?.grid.scrollback.nextCompressionWork()
    }
    mutating func installCompression(_ result: Scrollback.CompressionResult) {
        if scrollback.installCompression(result) { return }
        if let suspended = suspendedMain {
            var main = suspended.grid
            if main.scrollback.installCompression(result) { suspendedMain = SuspendedScreen(main) }
        }
    }

    /// Discards the scrollback, screen untouched — after pasting a secret —
    /// and the images wholly in it (`ED 3`).
    public mutating func clearScrollback() {
        imagePlacements.removePlacementsWhollyInScrollback(
            scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        scrollback.removeAll()
    }

    /// DECSTR (soft reset) resets modes without erasing the display or
    /// moving the active cursor.
    public mutating func softReset() {
        marginTop = 0
        marginBottom = rows - 1
        pen.reset()
        pendingWrap = false
        savedCursor = Cursor()
        savedPen = Pen()
        savedPendingWrap = false
        cursorStyle = .blinkingBlock
        cursorStyleIsExplicit = false
        // VT510's DECSTR table: cursor shown, absolute addressing, replace.
        isCursorVisible = true
        originMode = false
        savedOriginMode = false
        insertMode = false
    }

    /// DECALN: `E` everywhere, margins reset, cursor home, in the default pen.
    /// esctest uses it to reach a known state before every check, so ignoring it
    /// voids every test built on it.
    public mutating func alignmentDisplay() {
        marginTop = 0
        marginBottom = rows - 1
        pen.reset()
        pendingWrap = false
        cursor = Cursor(row: 0, column: 0)
        for _ in 0..<rows {
            for _ in 0..<columns {
                write(UInt32(UInt8(ascii: "E")))
            }
            pendingWrap = false
            if cursor.row < rows - 1 {
                cursor = Cursor(row: cursor.row + 1, column: 0)
            }
        }
        cursor = Cursor(row: 0, column: 0)
        pendingWrap = false
    }

    public mutating func setTabStop() {
        tabStops[cursor.column] = true
    }

    public mutating func clearTabStop(atCursorOnly: Bool) {
        if atCursorOnly {
            tabStops[cursor.column] = false
        } else {
            for index in tabStops.indices { tabStops[index] = false }
        }
    }

    static func defaultTabStops(columns: Int) -> ContiguousArray<Bool> {
        ContiguousArray((0..<columns).map { $0 > 0 && $0 % tabInterval == 0 })
    }

    mutating func resizeTabStops(to newColumns: Int) {
        if newColumns < tabStops.count {
            tabStops.removeLast(tabStops.count - newColumns)
        } else if newColumns > tabStops.count {
            let oldCount = tabStops.count
            tabStops.append(contentsOf: repeatElement(false, count: newColumns - oldCount))
            for column in oldCount..<newColumns where column > 0 && column % Self.tabInterval == 0 {
                tabStops[column] = true
            }
        }
    }

    /// LF, VT, FF: down one row; the column is CR's job.
    public mutating func lineFeed() {
        lineFeedWithoutClearingWrap()
        pendingWrap = false
    }

    public mutating func reverseIndex() {
        if cursor.row == marginTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
        pendingWrap = false
    }

    mutating func lineFeedWithoutClearingWrap() {
        if cursor.row == marginBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }
}
