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

    public init(rows: Int = 24, columns: Int = 80, scrollbackLimit: Int = Scrollback.defaultLimit) {
        self.rows = min(max(1, rows), Self.maxRows)
        self.columns = min(max(1, columns), Self.maxColumns)
        self.lines = ContiguousArray(repeating: Line(), count: self.rows)
        self.cursor = Cursor()
        self.pen = Pen()
        self.graphemes = GraphemeTable()
        self.scrollback = Scrollback(limit: scrollbackLimit)
        self.pendingWrap = false
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
}
