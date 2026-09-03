/// Where the next character is written.
public struct Cursor: Equatable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int = 0, column: Int = 0) {
        self.row = row
        self.column = column
    }
}

/// DECSCUSR (xterm ctlseqs, `CSI Ps SP q`): the cursor's shape and blink.
/// The core stores it; drawing it is the renderer's concern.
public enum CursorStyle: Equatable, Sendable {
    case blinkingBlock
    case block
    case blinkingUnderline
    case underline
    case blinkingBar
    case bar
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

    public internal(set) var rows: Int
    public internal(set) var columns: Int
    public internal(set) var lines: ContiguousArray<Line>

    public var cursor: Cursor
    public var pen: Pen

    /// DECSCUSR state (xterm ctlseqs). Global to the terminal rather than
    /// per screen: it survives an alternate-screen round trip.
    public var cursorStyle: CursorStyle = .blinkingBlock

    /// Grapheme clusters too large for a cell's single scalar
    /// (`DESIGN.md` §2.3). M2.1 populates it with combining-mark clusters;
    /// ZWJ sequences arrive with M3.6.
    public var graphemes: GraphemeTable

    /// OSC 8 hyperlink targets, keyed by the id a cell carries (M6.8).
    /// Shared with the alternate screen and never cleared while a link may
    /// still be on screen or in the scrollback — an id in a cell that no
    /// longer resolves would render as a link that goes nowhere.
    public var hyperlinks: HyperlinkTable

    /// Rows that have scrolled off the top.
    public var scrollback: Scrollback

    /// The deferred-wrap state of a real VT: printing into the last column
    /// leaves the cursor *on* that column and arms this flag. The next
    /// printable character wraps first, and only then is the row marked
    /// `wrapped`. Without the deferral, a program that fills the last column
    /// and then moves the cursor would scroll the screen by one row.
    public internal(set) var pendingWrap: Bool

    /// DECSC's slot — cursor, pen and wrap state (VT510 §DECSC).
    private var savedCursor: Cursor?
    private var savedPen: Pen?
    private var savedPendingWrap: Bool = false

    /// True while the alternate screen is live (roadmap M2.3).
    public private(set) var isAlternateScreenActive: Bool = false

    /// The parked main screen while the alternate screen is live.
    private var suspendedMain: SuspendedScreen?

    /// The scroll region (DECSTBM), zero-based and inclusive: the rows that
    /// scrolling moves. Everything outside the margins stays put. Defaults
    /// to the whole screen.
    public private(set) var marginTop: Int = 0
    public private(set) var marginBottom: Int

    public init(rows: Int = 24, columns: Int = 80, scrollbackLimit: Int = Scrollback.defaultLimit) {
        self.rows = min(max(1, rows), Self.maxRows)
        self.columns = min(max(1, columns), Self.maxColumns)
        self.lines = ContiguousArray(repeating: Line(), count: self.rows)
        self.cursor = Cursor()
        self.pen = Pen()
        self.cursorStyle = .blinkingBlock
        self.graphemes = GraphemeTable()
        self.hyperlinks = HyperlinkTable()
        self.scrollback = Scrollback(limit: scrollbackLimit)
        self.pendingWrap = false
        self.savedCursor = nil
        self.savedPen = nil
        self.savedPendingWrap = false
        self.isAlternateScreenActive = false
        self.suspendedMain = nil
        self.marginBottom = self.rows - 1
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

    /// Writes one scalar in the current pen at the cursor, then advances by
    /// the scalar's display width (0, 1 or 2 — `wcwidth`/xterm conventions,
    /// see `displayWidth`).
    public mutating func write(_ scalar: UInt32) {
        // Fast path: printable ASCII is width 1 by construction and never a
        // control — no table lookup, no scalar validation (`PERFORMANCE.md`
        // §3; this runs once per byte of output).
        if scalar >= 0x20, scalar < 0x7F {
            writeNarrow(scalar)
            return
        }
        // The parser never delivers controls or invalid scalars; if one
        // arrives anyway, it is not printable — and a C0/C1 control has
        // display width 0, which would corrupt the combining-mark path.
        guard let value = Unicode.Scalar(scalar), !Self.isControl(value) else { return }
        // M3.6: a scalar following a ZWJ-terminated cluster continues that
        // cluster — an emoji ZWJ sequence (👨‍👩‍👧‍👦) is one grapheme and
        // stays one (wide) cell, not one wide pair per emoji. ZWJ itself is
        // zero-width and arrives through `writeZeroWidth` as usual.
        if scalar != 0x200D, let target = clusterJoinTarget(), clusterEndsWithZWJ(target) {
            combine(scalar, row: target.row, column: target.column)
            return
        }
        // A flag is a *pair* of regional indicators and one grapheme (UAX #29
        // GB12/GB13), so the second indicator joins the first's cell instead
        // of claiming a wide pair of its own. Without this a two-letter flag
        // occupies four columns and every border drawn after it on the line
        // lands two columns late.
        if Self.isRegionalIndicator(scalar), let target = clusterJoinTarget(),
            endsWithLoneRegionalIndicator(target)
        {
            combine(scalar, row: target.row, column: target.column)
            return
        }
        switch displayWidth(of: value) {
        case 0:
            writeZeroWidth(scalar)
        case 2 where columns >= 2:
            writeWide(scalar)
        default:
            // A one-column screen cannot hold a pair; the wide scalar falls
            // back to a single cramped cell rather than vanishing.
            writeNarrow(scalar)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Width 1: the ordinary path — one cell, advance one column.
    private mutating func writeNarrow(_ scalar: UInt32) {
        if pendingWrap {
            // The row really did continue onto the next one. This is the
            // only place `wrapped` is ever set (`DESIGN.md` §2.1).
            lines[cursor.row].wrapped = true
            cursor.column = 0
            lineFeedWithoutClearingWrap()
        }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        lines[cursor.row][cursor.column] = pen.cell(scalar)
        if cursor.column + 1 >= columns {
            pendingWrap = true
        } else {
            cursor.column += 1
            pendingWrap = false
        }
    }

    /// Width 2: the scalar occupies two columns — its lead cell (flagged
    /// `.wide`) plus a spacer cell to its right (flagged `.wideSpacer`,
    /// holding a space so it draws and dumps as blank) — and the cursor
    /// advances 2.
    private mutating func writeWide(_ scalar: UInt32) {
        if !pendingWrap, cursor.column == columns - 1 {
            // Only the last column remains, and a pair may not straddle the
            // right margin: blank the column and wrap now, so the pair lands
            // intact on the next row (xterm does the same).
            blankWidePairHalves(row: cursor.row, column: cursor.column)
            lines[cursor.row][cursor.column] = pen.eraseCell
            pendingWrap = true
        }
        if pendingWrap {
            lines[cursor.row].wrapped = true
            cursor.column = 0
            lineFeedWithoutClearingWrap()
        }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        // The spacer may land on the lead of a later pair; blank it too.
        blankWidePairHalves(row: cursor.row, column: cursor.column + 1)
        var lead = pen.cell(scalar)
        lead.attributes.insert(.wide)
        var spacer = pen.cell(0x20)
        spacer.attributes.insert(.wideSpacer)
        lines[cursor.row][cursor.column] = lead
        lines[cursor.row][cursor.column + 1] = spacer
        if cursor.column + 2 >= columns {
            // The pair ended in the last column: the cursor rests on the
            // spacer with the wrap armed, exactly as a narrow write does.
            cursor.column = columns - 1
            pendingWrap = true
        } else {
            cursor.column += 2
            pendingWrap = false
        }
    }

    /// Width 0 (combining marks, ZWJ, variation selectors): the scalar joins
    /// the cluster of the previously written cell and the cursor does not
    /// move — a zero-width scalar never gets a cell of its own.
    private mutating func writeZeroWidth(_ scalar: UInt32) {
        guard let target = clusterJoinTarget() else {
            // No previous cell (start of output, hard newline). xterm keeps
            // the mark visible by storing it as a base character of its own
            // (charproc.c: "we will add the combining character as a base
            // character"), rather than dropping it.
            writeNarrow(scalar)
            return
        }
        combine(scalar, row: target.row, column: target.column)
    }

    /// The cell a zero-width scalar — or the continuation of a
    /// ZWJ-terminated cluster (M3.6) — joins: the previously written cell,
    /// following wraps and wide pairs. `nil` when there is no previous cell
    /// (start of output, hard newline).
    private func clusterJoinTarget() -> (row: Int, column: Int)? {
        var row = cursor.row
        var column: Int
        if pendingWrap {
            // The cursor rests on the last column, which is the last write.
            column = cursor.column
        } else if cursor.column > 0 {
            column = cursor.column - 1
        } else if cursor.row > 0, lines[cursor.row - 1].wrapped {
            // The logical line continues from the wrapped row above.
            row = cursor.row - 1
            column = columns - 1
        } else {
            return nil
        }
        // A mark after a wide pair belongs to the pair's lead cell.
        if column > 0, lines[row][column].attributes.contains(.wideSpacer) {
            column -= 1
        }
        return (row, column)
    }

    /// Whether the cell at `target` holds a cluster whose last scalar is
    /// ZWJ — the join condition for M3.6's ZWJ-continuation in `write`.
    /// Plain cells (`.none` id) answer false without touching the table, so
    /// ordinary CJK output pays a bounds check, not a lookup.
    private func clusterEndsWithZWJ(_ target: (row: Int, column: Int)) -> Bool {
        let cell = lines[target.row][target.column]
        guard !cell.grapheme.isNone else { return false }
        return graphemes.scalars(for: cell.grapheme)?.last == 0x200D
    }

    private static func isRegionalIndicator(_ scalar: UInt32) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar)
    }

    /// Whether the cell at `target` ends in an *unpaired* regional indicator,
    /// which is the join condition for the second half of a flag. GB12/GB13
    /// break between indicators only after an even number of them, so the
    /// trailing run decides: one indicator is still waiting for its pair, two
    /// are a finished flag and a third starts a new cell.
    private func endsWithLoneRegionalIndicator(_ target: (row: Int, column: Int)) -> Bool {
        let cell = lines[target.row][target.column]
        guard !cell.grapheme.isNone, let cluster = graphemes.scalars(for: cell.grapheme) else {
            return Self.isRegionalIndicator(cell.scalar)
        }
        var trailing = 0
        for scalar in cluster.reversed() {
            guard Self.isRegionalIndicator(scalar) else { break }
            trailing += 1
        }
        return trailing % 2 == 1
    }

    /// Appends `scalar` to the grapheme cluster of the cell at (`row`,
    /// `column`), interning the extended cluster in the side table
    /// (`DESIGN.md` §2.3).
    private mutating func combine(_ scalar: UInt32, row: Int, column: Int) {
        let cell = lines[row][column]
        var cluster = graphemes.scalars(for: cell.grapheme) ?? [cell.scalar]
        cluster.append(scalar)
        // The table is capped (`SECURITY.md` §3); when it is full, the mark
        // is dropped and the base character stays as it was.
        guard let id = graphemes.intern(cluster) else { return }
        var updated = cell
        updated.grapheme = id
        lines[row][column] = updated
    }

    /// Standard terminal behaviour: overwriting or erasing either half of a
    /// wide pair blanks BOTH halves — a dangling half would draw as a stray
    /// glyph or a stray blank. Blanks the half adjacent to (`row`, `column`)
    /// when that column holds one half of a pair.
    private mutating func blankWidePairHalves(row: Int, column: Int) {
        let cell = lines[row][column]
        if cell.attributes.contains(.wideSpacer), column > 0 {
            lines[row][column - 1] = pen.eraseCell
        } else if cell.attributes.contains(.wide), column + 1 < columns {
            lines[row][column + 1] = pen.eraseCell
        }
    }

    /// After a cell-shifting edit (ICH/DCH) a wide pair can be split across
    /// the edit boundary or the right margin. Blanks every half that lost
    /// its partner; blanking the lead of a broken pair orphans its spacer,
    /// which the same pass then blanks in turn.
    private mutating func repairWidePairs(row: Int, template: Cell) {
        var column = 0
        while column < lines[row].count {
            let cell = lines[row][column]
            if cell.attributes.contains(.wide) {
                let intact =
                    column + 1 < columns
                    && lines[row][column + 1].attributes.contains(.wideSpacer)
                if !intact { lines[row][column] = template }
            } else if cell.attributes.contains(.wideSpacer) {
                let intact =
                    column > 0
                    && lines[row][column - 1].attributes.contains(.wide)
                if !intact { lines[row][column] = template }
            }
            column += 1
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
        if cursor.row == marginBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
        // Below the bottom margin a line feed neither scrolls nor wraps
        // around: the cursor just stops at the last row.
    }

    // MARK: - Erasing

    public mutating func eraseLine(_ mode: LineEraseMode) {
        let template = pen.eraseCell
        switch mode {
        case .toEnd:
            // Erasing rightwards from a spacer would orphan the pair's lead
            // just left of the range: start one column earlier so both
            // halves go. Erasing from a lead needs nothing — its spacer is
            // inside the range.
            var start = cursor.column
            if start > 0, lines[cursor.row][start].attributes.contains(.wideSpacer) {
                start -= 1
            }
            lines[cursor.row].erase(start..<columns, with: template)
            lines[cursor.row].wrapped = false
        case .toStart:
            // Symmetrically, erasing leftwards ending on a lead would orphan
            // its spacer just right of the range: extend by one column.
            var end = cursor.column + 1
            if end < columns, lines[cursor.row][cursor.column].attributes.contains(.wide) {
                end += 1
            }
            lines[cursor.row].erase(0..<end, with: template)
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

    /// Changes the visible dimensions. A column change reflows the document
    /// (`DESIGN.md` §2.1, roadmap M4.2) — except on the alternate screen,
    /// which has no scrollback and is resized, never reflowed, because a
    /// full-screen application redraws itself on `SIGWINCH` and re-wrapping
    /// what it drew would corrupt its own model of the screen. A row-only
    /// change keeps the cheaper non-reflowing path: rows move to or from
    /// scrollback without touching any row's content.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        let newRows = min(max(1, newRows), Self.maxRows)
        let newColumns = min(max(1, newColumns), Self.maxColumns)
        guard newRows != rows || newColumns != columns else { return }

        if newColumns != columns, !isAlternateScreenActive {
            reflow(toColumns: newColumns, newRows: newRows)
            rows = newRows
            marginTop = min(marginTop, rows - 1)
            marginBottom = min(marginBottom, rows - 1)
            if marginTop >= marginBottom {
                marginTop = 0
                marginBottom = rows - 1
            }
            return
        }

        if newRows < rows {
            // Take the rows off the TOP, into scrollback — not off the
            // bottom. The bottom is where the cursor and the newest output
            // are; truncating there destroys the most recent lines outright,
            // and silently, since they never reach the history either.
            // Shrinking a window used to eat the last commands you ran.
            //
            // Only as many rows as it takes to keep the cursor on screen
            // move up; anything still surplus is below the cursor and blank,
            // so it comes off the bottom as before.
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
        columns = newColumns
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        pendingWrap = false
        marginTop = min(marginTop, rows - 1)
        marginBottom = min(marginBottom, rows - 1)
        if marginTop >= marginBottom {
            // The region no longer fits; fall back to the whole screen.
            marginTop = 0
            marginBottom = rows - 1
        }
    }

    // MARK: - Scroll region

    /// DECSTBM — VT510 §DECSTBM: sets the top and bottom margins, zero-based
    /// and inclusive here (the wire is one-based; that is the performer's
    /// problem), then homes the cursor. A region is at least two rows;
    /// `top >= bottom` after clamping is ignored, margins unchanged.
    public mutating func setScrollRegion(top: Int, bottom: Int) {
        let top = max(0, top)
        let bottom = min(bottom, rows - 1)
        guard top < bottom else { return }
        marginTop = top
        marginBottom = bottom
        moveCursor(row: 0, column: 0)
    }

    // MARK: - Scrolling

    /// Moves the scroll region up by `count` rows, opening blank rows at the
    /// bottom margin. Rows above the top margin and below the bottom margin
    /// stay put.
    ///
    /// What falls off the top goes to the scrollback only when the region is
    /// the whole screen — a partial region belongs to an application (a tmux
    /// status line, a vim window), and its scrolled-off rows are not the
    /// user's history. The rows that do go keep their `wrapped` flag, so a
    /// command that soft-wrapped before it scrolled is still one logical
    /// line to selection and search (`DESIGN.md` §2.1).
    public mutating func scrollUp(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        let saveToHistory = marginTop == 0 && marginBottom == rows - 1
        for row in marginTop..<(marginBottom - count + 1) {
            if saveToHistory, row < marginTop + count {
                scrollback.push(lines[row])
            }
            lines[row] = lines[row + count]
        }
        for row in (marginBottom - count + 1)...marginBottom {
            lines[row] = Line()
        }
    }

    /// SD — ECMA-48 §8.3.113: moves the scroll region down by `count` rows,
    /// opening blank rows at the top margin. Rows outside the margins stay
    /// put, and nothing enters the scrollback — scrolling down revisits
    /// content, it does not create history.
    public mutating func scrollDown(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        var row = marginBottom
        while row >= marginTop + count {
            lines[row] = lines[row - count]
            row -= 1
        }
        while row >= marginTop {
            lines[row] = Line()
            row -= 1
        }
    }

    // MARK: - Editing

    /// IL — ECMA-48 §8.3.67: inserts `count` erased rows at the cursor row,
    /// shifting rows below it down within the scroll region; rows pushed
    /// past the bottom margin are lost. Ignored when the cursor is outside
    /// the region. The cursor does not move.
    public mutating func insertLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        var row = marginBottom
        while row >= cursor.row + count {
            lines[row] = lines[row - count]
            row -= 1
        }
        while row >= cursor.row {
            lines[row] = erasedLine()
            row -= 1
        }
        pendingWrap = false
    }

    /// DL — ECMA-48 §8.3.32: deletes `count` rows at the cursor row,
    /// shifting rows below it up within the scroll region; erased rows open
    /// at the bottom margin. Deleted rows are application content, never
    /// history. Ignored when the cursor is outside the region. The cursor
    /// does not move.
    public mutating func deleteLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        var row = cursor.row
        while row + count <= marginBottom {
            lines[row] = lines[row + count]
            row += 1
        }
        while row <= marginBottom {
            lines[row] = erasedLine()
            row += 1
        }
        pendingWrap = false
    }

    /// ICH — ECMA-48 §8.3.64: inserts `count` erased cells at the cursor.
    /// The cursor does not move.
    public mutating func insertCharacters(_ count: Int) {
        lines[cursor.row].insertCells(count, at: cursor.column, template: pen.eraseCell, width: columns)
        repairWidePairs(row: cursor.row, template: pen.eraseCell)
        pendingWrap = false
    }

    /// DCH — ECMA-48 §8.3.26: deletes `count` cells at the cursor. The
    /// cursor does not move.
    public mutating func deleteCharacters(_ count: Int) {
        lines[cursor.row].deleteCells(count, at: cursor.column, template: pen.eraseCell, width: columns)
        repairWidePairs(row: cursor.row, template: pen.eraseCell)
        pendingWrap = false
    }

    /// A cleared row: blank, or filled with the erase background when one is
    /// set (BCE — an erased cell under a colour is visible, so it is stored).
    private func erasedLine() -> Line {
        let template = pen.eraseCell
        guard !template.isBlank else { return Line() }
        var line = Line()
        line.fill(template, in: 0..<columns)
        return line
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
            marginTop = 0
            marginBottom = rows - 1
            moveCursor(row: 0, column: 0)
            return
        }
        suspendedMain = SuspendedScreen(self)
        lines = ContiguousArray(repeating: Line(), count: rows)
        scrollback = Scrollback(limit: 0)
        graphemes = GraphemeTable()
        marginTop = 0
        marginBottom = rows - 1
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
        main.cursorStyle = cursorStyle  // the style is global, not per screen
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
