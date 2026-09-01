/// Where the next character is written.
public struct Cursor: Equatable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int = 0, column: Int = 0) {
        self.row = row
        self.column = column
    }
}

public enum LineEraseMode: Sendable {
    /// EL 0 — the cursor and everything right of it.
    case toEnd
    /// EL 1 — everything left of the cursor, and the cursor.
    case toStart
    /// EL 2 — the whole row.
    case all
}

public enum DisplayEraseMode: Sendable {
    /// ED 0 — the cursor to the end of the screen.
    case toEnd
    /// ED 1 — the start of the screen to the cursor.
    case toStart
    /// ED 2 — the whole screen.
    case all
}

/// The visible screen: rows of cells, a cursor, and the current pen.
///
/// This type knows nothing about escape sequences. It offers the operations
/// a terminal performs — write a character, move, erase, feed a line, scroll
/// — and `Performer` is what decides that `ESC [ 2 J` means `eraseDisplay`.
/// Keeping the split lets the grid be tested without a parser and the parser
/// without a screen.
public struct Grid: Sendable {
    /// Sanity bounds. A window cannot be this large; a hostile resize
    /// request or a corrupt parameter can ask for it (`SECURITY.md` §3).
    public static let maxRows = 4096
    public static let maxColumns = 4096

    public private(set) var rows: Int
    public private(set) var columns: Int
    public private(set) var lines: ContiguousArray<Line>

    public var cursor: Cursor
    public var pen: Pen

    /// Grapheme clusters too large for a cell's single scalar
    /// (`DESIGN.md` §2.3). Unused until M2.1 adds character widths.
    public var graphemes: GraphemeTable

    /// Rows that have scrolled off the top.
    public var scrollback: Scrollback

    /// The deferred-wrap state of a real VT: printing into the last column
    /// leaves the cursor *on* that column and arms this flag. The next
    /// printable character wraps first, and only then is the row marked
    /// `wrapped`. Without the deferral, a program that fills the last column
    /// and then moves the cursor would scroll the screen by one row.
    public private(set) var pendingWrap: Bool

    /// DECSC's slot — cursor, pen and wrap state (VT510 §DECSC).
    private var savedCursor: Cursor?
    private var savedPen: Pen?
    private var savedPendingWrap: Bool = false

    /// True while the alternate screen is live (roadmap M2.3).
    public private(set) var isAlternateScreenActive: Bool = false

    /// The parked main screen while the alternate screen is live.
    private var suspendedMain: SuspendedScreen?

    public init(rows: Int = 24, columns: Int = 80, scrollbackLimit: Int = Scrollback.defaultLimit) {
        self.rows = min(max(1, rows), Self.maxRows)
        self.columns = min(max(1, columns), Self.maxColumns)
        self.lines = ContiguousArray(repeating: Line(), count: self.rows)
        self.cursor = Cursor()
        self.pen = Pen()
        self.graphemes = GraphemeTable()
        self.scrollback = Scrollback(limit: scrollbackLimit)
        self.pendingWrap = false
        self.savedCursor = nil
        self.savedPen = nil
        self.savedPendingWrap = false
        self.isAlternateScreenActive = false
        self.suspendedMain = nil
    }

    // MARK: - Reading

    public subscript(row: Int, column: Int) -> Cell {
        @inline(__always)
        get {
            guard row >= 0, row < rows else { return .blank }
            return lines[row][column]
        }
    }

    public func line(_ row: Int) -> Line {
        guard row >= 0, row < rows else { return Line() }
        return lines[row]
    }

    // MARK: - Writing

    /// Writes one scalar in the current pen at the cursor, then advances.
    public mutating func write(_ scalar: UInt32) {
        if pendingWrap {
            // The row really did continue onto the next one. This is the
            // only place `wrapped` is ever set (`DESIGN.md` §2.1).
            lines[cursor.row].wrapped = true
            cursor.column = 0
            lineFeedWithoutClearingWrap()
        }
        lines[cursor.row][cursor.column] = pen.cell(scalar)
        if cursor.column + 1 >= columns {
            pendingWrap = true
        } else {
            cursor.column += 1
            pendingWrap = false
        }
    }

    // MARK: - Cursor movement

    /// Absolute positioning, clamped to the screen. Zero-based; CUP's
    /// one-based parameters are the performer's problem.
    public mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(0, row), rows - 1)
        cursor.column = min(max(0, column), columns - 1)
        pendingWrap = false
    }

    public mutating func moveCursorUp(_ count: Int = 1) {
        moveCursor(row: cursor.row - max(0, count), column: cursor.column)
    }

    public mutating func moveCursorDown(_ count: Int = 1) {
        moveCursor(row: cursor.row + max(0, count), column: cursor.column)
    }

    public mutating func moveCursorLeft(_ count: Int = 1) {
        moveCursor(row: cursor.row, column: cursor.column - max(0, count))
    }

    public mutating func moveCursorRight(_ count: Int = 1) {
        moveCursor(row: cursor.row, column: cursor.column + max(0, count))
    }

    /// CR — column 0, same row.
    public mutating func carriageReturn() {
        cursor.column = 0
        pendingWrap = false
    }

    /// BS — one column left, stopping at the left margin. A backspace out of
    /// the armed wrap state disarms it rather than moving, which is what
    /// keeps `printf 'x%80s' ; printf '\b'` from stepping off the row.
    public mutating func backspace() {
        if pendingWrap {
            pendingWrap = false
            return
        }
        if cursor.column > 0 { cursor.column -= 1 }
    }

    /// HT — the next tab stop. Stops are every eight columns; DECST8C and a
    /// programmable stop table arrive with M2.
    public mutating func tab() {
        let next = (cursor.column / Self.tabInterval + 1) * Self.tabInterval
        cursor.column = min(next, columns - 1)
        pendingWrap = false
    }

    public static let tabInterval = 8

    /// LF, VT, FF — down one row, scrolling at the bottom. The column does
    /// not change; that is CR's job.
    public mutating func lineFeed() {
        lineFeedWithoutClearingWrap()
        pendingWrap = false
    }

    private mutating func lineFeedWithoutClearingWrap() {
        if cursor.row + 1 >= rows {
            scrollUp(1)
        } else {
            cursor.row += 1
        }
    }

    // MARK: - Erasing

    public mutating func eraseLine(_ mode: LineEraseMode) {
        let template = pen.eraseCell
        switch mode {
        case .toEnd:
            lines[cursor.row].erase(cursor.column..<columns, with: template)
            lines[cursor.row].wrapped = false
        case .toStart:
            lines[cursor.row].erase(0..<(cursor.column + 1), with: template)
        case .all:
            lines[cursor.row].erase(0..<columns, with: template)
            lines[cursor.row].wrapped = false
        }
    }

    public mutating func eraseDisplay(_ mode: DisplayEraseMode) {
        let template = pen.eraseCell
        switch mode {
        case .toEnd:
            eraseLine(.toEnd)
            for row in (cursor.row + 1)..<rows {
                eraseWholeLine(row, with: template)
            }
        case .toStart:
            for row in 0..<cursor.row {
                eraseWholeLine(row, with: template)
            }
            eraseLine(.toStart)
        case .all:
            for row in 0..<rows {
                eraseWholeLine(row, with: template)
            }
        }
    }

    private mutating func eraseWholeLine(_ row: Int, with template: Cell) {
        if template.isBlank {
            lines[row].clear()
        } else {
            lines[row].erase(0..<columns, with: template)
            lines[row].wrapped = false
        }
    }

    // MARK: - Resizing

    /// Changes the visible dimensions without reflowing content — rows are
    /// truncated or padded, and columns beyond the new width are simply not
    /// read (`Line` stores only up to its last written column already).
    /// Reflow (`DESIGN.md` §2.1, roadmap M4.1) rewraps history to the new
    /// width; that is deliberately not this method's job.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        let newRows = min(max(1, newRows), Self.maxRows)
        let newColumns = min(max(1, newColumns), Self.maxColumns)
        guard newRows != rows || newColumns != columns else { return }

        if newRows < rows {
            lines.removeLast(rows - newRows)
        } else if newRows > rows {
            lines.append(contentsOf: repeatElement(Line(), count: newRows - rows))
        }
        rows = newRows
        columns = newColumns
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        pendingWrap = false
    }

    // MARK: - Scrolling

    /// Moves the screen up by `count` rows, giving what falls off the top to
    /// the scrollback and opening blank rows at the bottom.
    ///
    /// The rows keep their `wrapped` flag on the way into history, so a
    /// command that soft-wrapped before it scrolled is still one logical
    /// line to selection and search (`DESIGN.md` §2.1).
    public mutating func scrollUp(_ count: Int) {
        let count = min(max(0, count), rows)
        guard count > 0 else { return }
        for row in 0..<count {
            scrollback.push(lines[row])
        }
        lines.removeFirst(count)
        for _ in 0..<count {
            lines.append(Line())
        }
    }

    // MARK: - Save and restore

    /// DECSC — VT510 §DECSC: saves the cursor position, the pen and the
    /// pending-wrap state. The origin-mode and character-set state the full
    /// spec lists are not implemented (DECOM is out of scope for M2; the
    /// parser never selects a character set).
    public mutating func saveCursor() {
        savedCursor = cursor
        savedPen = pen
        savedPendingWrap = pendingWrap
    }

    /// DECRC — VT510 §DECRC. With nothing saved, the spec restores the
    /// factory settings: home position and the default rendition.
    public mutating func restoreCursor() {
        guard let savedCursor, let savedPen else {
            moveCursor(row: 0, column: 0)
            pen.reset()
            return
        }
        moveCursor(row: savedCursor.row, column: savedCursor.column)
        pen = savedPen
        pendingWrap = savedPendingWrap
    }

    // MARK: - Alternate screen

    /// `?1049` set (xterm ctlseqs, DEC Private Mode Set): save the cursor,
    /// switch to the alternate screen, clear it.
    ///
    /// The alternate screen is a second screen swapped in, not a flag on
    /// this one's storage: the main screen — lines, scrollback, margins,
    /// pen — is parked whole in `suspendedMain` and put back untouched on
    /// the way out. The alternate screen itself is blank, has full-screen
    /// margins, and has **no scrollback** (a zero-limit ring whose push is
    /// a no-op): history scrolled while it is live is discarded.
    public mutating func enterAlternateScreen() {
        saveCursor()
        guard suspendedMain == nil else {
            // A second `?1049 h` while already active re-saves the cursor and
            // clears again; the parked screen stays the original main one.
            eraseDisplay(.all)
            moveCursor(row: 0, column: 0)
            return
        }
        suspendedMain = SuspendedScreen(self)
        lines = ContiguousArray(repeating: Line(), count: rows)
        scrollback = Scrollback(limit: 0)
        graphemes = GraphemeTable()
        isAlternateScreenActive = true
        moveCursor(row: 0, column: 0)
    }

    /// `?1049` reset: switch back to the main screen and restore the cursor
    /// that was saved on the way in. Ignored when the main screen is live.
    ///
    /// If the screen was resized while the alternate screen was live, the
    /// parked main screen adopts the new dimensions on its way back — the
    /// size belongs to the window, not to a screen.
    public mutating func exitAlternateScreen() {
        guard let suspended = suspendedMain else { return }
        suspendedMain = nil
        var main = suspended.grid
        if main.rows != rows || main.columns != columns {
            main.resize(rows: rows, columns: columns)
        }
        self = main
        restoreCursor()
    }
}

/// The parked main screen of a grid whose alternate screen is live.
///
/// A value type cannot store another instance of itself inline, so the one
/// parked screen sits behind a single reference. It is written once on the
/// way into the alternate screen and only ever read on the way out, so the
/// snapshots the renderer may be holding can share it without ever
/// observing a mutation — that is what makes the `Sendable` conformance
/// honest.
private final class SuspendedScreen: @unchecked Sendable {
    let grid: Grid

    init(_ grid: Grid) {
        self.grid = grid
    }
}
