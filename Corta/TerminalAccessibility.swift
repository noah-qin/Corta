import AppKit
import CortaTerminal

/// A flattened copy of what one pane is showing, in the shape the AppKit
/// accessibility protocols ask for: one string, plus enough index to answer
/// "which line is offset 4102 on" without rebuilding anything.
///
/// **Why a snapshot and not live queries.** `NSAccessibility` asks a dozen
/// questions per VoiceOver step, each of which would otherwise take the
/// terminal's lock and walk the grid. One copy per burst answers all of them
/// consistently — a value read half-way through a parse batch would have a
/// selection range that does not match the text it indexes.
///
/// **Why the viewport and not the scrollback.** The exposed value is the
/// visible rows only. A 100k-line scrollback is a ~10 MB string that would be
/// rebuilt on every notification, and — the actual reason — an assistive
/// technology's idea of "the text area" is what is on screen; history is
/// reached by scrolling, exactly as a sighted user reaches it.
struct TerminalAccessibilitySnapshot {
    /// The visible rows, newline-joined, trailing blanks trimmed per row.
    let text: String
    /// `lineStarts[i]` is the UTF-16 offset in `text` at which visible row
    /// `i` begins. One entry per row, always — a blank row still has a
    /// position.
    let lineStarts: [Int]
    /// Grid geometry, spoken as part of the element's description: a terminal
    /// without its row and column count is missing the one fact that explains
    /// why a program's output is laid out the way it is.
    let rows: Int
    let columns: Int
    /// Where the cursor is, in grid coordinates.
    let cursorRow: Int
    let cursorColumn: Int
    /// The cursor as a UTF-16 offset in `text` — the insertion point.
    let cursorOffset: Int
    /// The selection, as a range in `text`, clipped to the viewport. Empty at
    /// the insertion point when there is no selection, which is what a text
    /// area is expected to report.
    let selectedRange: NSRange

    /// Builds the snapshot from a grid copy.
    ///
    /// `NSRange` is UTF-16, the grid is columns, and the two only coincide for
    /// ASCII — `rowTextWithColumns` supplies the mapping so a selection over
    /// CJK or an emoji lands on the characters it actually covers.
    init(grid: Grid, selection: SelectionRange?) {
        var text = ""
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(grid.rows)
        // Column -> UTF-16 offset within the row, one map per visible row.
        var columnOffsets: [[Int: Int]] = []
        columnOffsets.reserveCapacity(grid.rows)
        var rowLengths: [Int] = []
        rowLengths.reserveCapacity(grid.rows)

        for row in 0..<grid.rows {
            lineStarts.append(text.utf16.count)
            let (rowText, columns) = grid.rowTextWithColumns(row)
            var offsets: [Int: Int] = [:]
            var utf16Offset = 0
            for (index, character) in rowText.enumerated() {
                if index < columns.count { offsets[columns[index]] = utf16Offset }
                utf16Offset += character.utf16.count
            }
            offsets[-1] = utf16Offset  // the end of the row, for a clamp
            columnOffsets.append(offsets)
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

        func offset(row: Int, column: Int) -> Int {
            // Rows outside the viewport clamp to its ends: a selection that
            // started in the scrollback is still reported, as the part of it
            // that is on screen.
            guard row >= 0 else { return 0 }
            guard row < lineStarts.count else { return text.utf16.count }
            let start = lineStarts[row]
            if let exact = columnOffsets[row][column] { return start + exact }
            // Past the last non-blank cell — the trimmed tail. Clamp to the
            // row's end rather than running into the next line.
            return start + min(rowLengths[row], column)
        }

        self.cursorOffset = offset(row: grid.cursor.row, column: grid.cursor.column)
        if let selection {
            let start = offset(row: selection.start.row, column: selection.start.column)
            let end = offset(row: selection.end.row, column: selection.end.column)
            self.selectedRange = NSRange(location: min(start, end), length: abs(end - start))
        } else {
            self.selectedRange = NSRange(location: cursorOffset, length: 0)
        }
    }
}
