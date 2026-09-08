import AppKit
import CortaTerminal

/// A flattened copy of what one pane is showing, in the shape the AppKit
/// accessibility protocols ask for: one string, plus enough index to answer
/// "which line is offset 4102 on" — and, in both directions, "which cell is
/// that character in" — without rebuilding anything.
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
/// reached by scrolling, exactly as a sighted user reaches it. "Visible"
/// means visible: the snapshot is taken at the current `scrollOffset`, so a
/// reader scrolled into the history hears the history rather than the live
/// screen behind it (U01).
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
    /// How far the viewport is scrolled back, in rows. Document row `r` is
    /// visible row `r + scrollOffset`.
    let scrollOffset: Int

    /// Per visible row, the character boundaries as (UTF-16 offset within the
    /// row, grid column) in ascending order.
    ///
    /// **This is the whole point of the type.** `NSRange` counts UTF-16 code
    /// units and the grid counts columns, and the two coincide only for
    /// ASCII: a CJK character is one column pair and one UTF-16 unit, an
    /// astral emoji is two columns and *two* UTF-16 units, and a combining
    /// mark is zero extra columns and one or more extra units. Anything that
    /// converts between the two by treating them as equal is wrong the moment
    /// a person types 中文 — which is exactly the content a screen-reader
    /// user is most likely to be navigating by cell.
    private let rowBoundaries: [[(offset: Int, column: Int)]]
    /// The UTF-16 length of each visible row's text, for clamping past the
    /// trimmed tail.
    private let rowLengths: [Int]

    /// Builds the snapshot from a grid copy.
    ///
    /// - Parameter scrollOffset: rows scrolled back from the live screen;
    ///   `0` is the bottom. Rows are read as *document* rows so the snapshot
    ///   is what is on screen, and `selection` — which is document-anchored
    ///   (`DESIGN.md` §2.7) — indexes into it without a second convention.
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
            // A document row: the live screen is 0..<rows, the scrollback
            // counts backwards from it.
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

        // A method cannot be called before every stored property is
        // initialised, so the rule itself lives in one static place and both
        // the initialiser and `offset(documentRow:column:)` call it — a
        // second copy inline here is a second copy to keep in step.
        func offset(documentRow: Int, column: Int) -> Int {
            Self.offset(
                documentRow: documentRow, column: column, lineStarts: lineStarts,
                rowBoundaries: rowBoundaries, rowLengths: rowLengths,
                textLength: text.utf16.count, scrollOffset: scrollOffset)
        }

        self.cursorOffset = offset(documentRow: grid.cursor.row, column: grid.cursor.column)
        if let selection {
            let start = offset(documentRow: selection.start.row, column: selection.start.column)
            let end = offset(documentRow: selection.end.row, column: selection.end.column)
            self.selectedRange = NSRange(location: min(start, end), length: abs(end - start))
        } else {
            self.selectedRange = NSRange(location: cursorOffset, length: 0)
        }
    }

    /// Rows outside the viewport clamp to its ends: a selection that started
    /// in the scrollback is still reported, as the part of it that is on
    /// screen. A column past the row's trimmed tail clamps to the row rather
    /// than running into the next line.
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

    // MARK: - The two conversions

    /// The UTF-16 offset in `text` of the character in document row
    /// `documentRow`, column `column`.
    func offset(documentRow: Int, column: Int) -> Int {
        Self.offset(
            documentRow: documentRow, column: column, lineStarts: lineStarts,
            rowBoundaries: rowBoundaries, rowLengths: rowLengths,
            textLength: text.utf16.count, scrollOffset: scrollOffset)
    }

    /// The inverse: the visible row and grid column a UTF-16 offset falls in.
    ///
    /// An offset inside a multi-unit character answers with that character's
    /// cell rather than splitting it, and an offset past a row's trimmed tail
    /// answers with the column the tail would have been at — VoiceOver asks
    /// for the frame of a range it was given, and "no such cell" is not an
    /// answer it can draw.
    func cell(forOffset offset: Int) -> (row: Int, column: Int) {
        guard !lineStarts.isEmpty else { return (0, 0) }
        let clamped = min(max(0, offset), text.utf16.count)
        var row = 0
        for (index, start) in lineStarts.enumerated() where start <= clamped { row = index }
        let within = clamped - lineStarts[row]
        guard let boundary = rowBoundaries[row].last(where: { $0.offset <= within }) else {
            return (row, within)
        }
        // Past the last character on the row: keep counting in columns from
        // the last one, so the trimmed blank tail still maps somewhere.
        if within > rowLengths[row] - 1, within >= rowLengths[row] {
            return (row, boundary.column + (within - boundary.offset))
        }
        return (row, boundary.column)
    }
}
