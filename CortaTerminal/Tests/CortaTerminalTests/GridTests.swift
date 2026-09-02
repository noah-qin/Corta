import Testing

@testable import CortaTerminal

/// M1.4 — the grid API, driven directly. No parser, no escape sequences.
@Suite("Grid")
struct GridTests {
    /// Writes `text` as ASCII. The parser does not exist yet at this step.
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    @Test("a new grid is blank with the cursor at the origin")
    func newGridIsBlank() {
        let grid = Grid(rows: 4, columns: 10)
        #expect(grid.rows == 4)
        #expect(grid.columns == 10)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
        #expect(grid[0, 0] == .blank)
        #expect(grid[3, 9] == .blank)
    }

    @Test("dimensions are clamped to something a screen could be")
    func dimensionsAreClamped() {
        #expect(Grid(rows: 0, columns: 0).rows == 1)
        #expect(Grid(rows: 0, columns: 0).columns == 1)
        #expect(Grid(rows: 1_000_000, columns: 1_000_000).rows == Grid.maxRows)
        #expect(Grid(rows: 1_000_000, columns: 1_000_000).columns == Grid.maxColumns)
    }

    @Test("writing advances the cursor and stores the pen")
    func writingStoresThePen() {
        var grid = Grid(rows: 4, columns: 10)
        grid.pen.foreground = .indexed(3)
        grid.pen.attributes = .bold
        write("hi", to: &grid)

        #expect(grid.cursor == Cursor(row: 0, column: 2))
        #expect(grid[0, 0].scalar == 0x68)
        #expect(grid[0, 0].foreground == .indexed(3))
        #expect(grid[0, 0].attributes == .bold)
        #expect(grid[0, 1].scalar == 0x69)
        #expect(grid[0, 2] == .blank)
    }

    // MARK: - Deferred wrap

    /// DEC STD 070 and every xterm-compatible terminal: a character printed
    /// into the last column leaves the cursor on that column with wrap
    /// pending. It is the *next* printable character that wraps.
    @Test("the cursor stays in the last column until the next character")
    func wrapIsDeferred() {
        var grid = Grid(rows: 4, columns: 4)
        write("abcd", to: &grid)

        #expect(grid.cursor == Cursor(row: 0, column: 3))
        #expect(grid.pendingWrap)
        #expect(!grid.line(0).wrapped)

        write("e", to: &grid)
        #expect(grid.cursor == Cursor(row: 1, column: 1))
        #expect(grid.line(0).wrapped)
        #expect(grid[1, 0].scalar == 0x65)
    }

    /// The wrap flag is what tells reflow, selection and search that two
    /// rows are one logical line (`DESIGN.md` §2.1). A newline must not set
    /// it, or copying two separate commands would join them.
    @Test("an explicit line feed does not set the wrap flag")
    func lineFeedDoesNotWrap() {
        var grid = Grid(rows: 4, columns: 4)
        write("ab", to: &grid)
        grid.lineFeed()
        grid.carriageReturn()
        write("cd", to: &grid)

        #expect(!grid.line(0).wrapped)
        #expect(grid.cursor == Cursor(row: 1, column: 2))
    }

    @Test("moving the cursor disarms a pending wrap")
    func cursorMovementDisarmsPendingWrap() {
        var grid = Grid(rows: 4, columns: 4)
        write("abcd", to: &grid)
        #expect(grid.pendingWrap)
        grid.moveCursorLeft(1)
        #expect(!grid.pendingWrap)
        #expect(grid.cursor == Cursor(row: 0, column: 2))
    }

    @Test("backspace out of a pending wrap disarms instead of moving")
    func backspaceDisarmsPendingWrap() {
        var grid = Grid(rows: 4, columns: 4)
        write("abcd", to: &grid)
        grid.backspace()
        #expect(!grid.pendingWrap)
        #expect(grid.cursor == Cursor(row: 0, column: 3))

        grid.backspace()
        #expect(grid.cursor == Cursor(row: 0, column: 2))
    }

    @Test("backspace stops at the left margin")
    func backspaceStopsAtTheMargin() {
        var grid = Grid(rows: 4, columns: 4)
        grid.backspace()
        #expect(grid.cursor == Cursor(row: 0, column: 0))
    }

    // MARK: - Movement

    @Test("cursor movement is clamped to the screen")
    func movementIsClamped() {
        var grid = Grid(rows: 4, columns: 10)
        grid.moveCursor(row: 2, column: 5)
        #expect(grid.cursor == Cursor(row: 2, column: 5))

        grid.moveCursorUp(100)
        #expect(grid.cursor == Cursor(row: 0, column: 5))
        grid.moveCursorDown(100)
        #expect(grid.cursor == Cursor(row: 3, column: 5))
        grid.moveCursorRight(100)
        #expect(grid.cursor == Cursor(row: 3, column: 9))
        grid.moveCursorLeft(100)
        #expect(grid.cursor == Cursor(row: 3, column: 0))
        grid.moveCursor(row: -5, column: -5)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
    }

    /// VT100 User Guide: default tab stops are every eight columns.
    @Test("tab lands on every eighth column and stops at the margin")
    func tabStopsAreEveryEight() {
        var grid = Grid(rows: 2, columns: 20)
        grid.tab()
        #expect(grid.cursor.column == 8)
        grid.tab()
        #expect(grid.cursor.column == 16)
        grid.tab()
        #expect(grid.cursor.column == 19)
    }

    @Test("a line feed on the last row scrolls instead of moving")
    func lineFeedScrollsAtTheBottom() {
        var grid = Grid(rows: 3, columns: 10)
        write("one", to: &grid)
        grid.lineFeed()
        grid.carriageReturn()
        write("two", to: &grid)
        grid.lineFeed()
        grid.carriageReturn()
        write("three", to: &grid)
        #expect(grid.cursor == Cursor(row: 2, column: 5))

        grid.lineFeed()
        #expect(grid.cursor == Cursor(row: 2, column: 5))
        #expect(grid[0, 0].scalar == 0x74)  // "two"
        #expect(grid[1, 0].scalar == 0x74)  // "three"
        #expect(grid.line(2).isEmpty)
    }

    @Test("scrolling by more than the screen height clears it")
    func scrollingPastTheScreenClearsIt() {
        var grid = Grid(rows: 3, columns: 10)
        write("one", to: &grid)
        grid.scrollUp(99)
        #expect(grid.rows == 3)
        for row in 0..<3 { #expect(grid.line(row).isEmpty) }
    }

    // MARK: - Erasing

    @Test("erase to end of line clears the cursor cell and the tail")
    func eraseToEndOfLine() {
        var grid = Grid(rows: 2, columns: 10)
        write("abcdef", to: &grid)
        grid.moveCursor(row: 0, column: 3)
        grid.eraseLine(.toEnd)

        #expect(grid[0, 2].scalar == 0x63)
        #expect(grid[0, 3] == .blank)
        #expect(grid[0, 5] == .blank)
        #expect(grid.line(0).count == 3)
    }

    @Test("erase to start of line includes the cursor cell")
    func eraseToStartOfLine() {
        var grid = Grid(rows: 2, columns: 10)
        write("abcdef", to: &grid)
        grid.moveCursor(row: 0, column: 3)
        grid.eraseLine(.toStart)

        #expect(grid[0, 3] == .blank)
        #expect(grid[0, 4].scalar == 0x65)
    }

    /// Background colour erase, as in xterm: erased cells take the current
    /// background but no foreground or attributes.
    @Test("erasing under a background colour paints it")
    func erasingPaintsTheBackground() {
        var grid = Grid(rows: 2, columns: 6)
        grid.pen.background = .indexed(4)
        grid.pen.foreground = .indexed(1)
        grid.pen.attributes = .underline
        grid.eraseLine(.all)

        #expect(grid[0, 5].background == .indexed(4))
        #expect(grid[0, 5].foreground == .default)
        #expect(grid[0, 5].attributes.isEmpty)
        #expect(grid.line(0).count == 6)
    }

    @Test("erase display to end clears the rest of the screen")
    func eraseDisplayToEnd() {
        var grid = Grid(rows: 3, columns: 6)
        for row in 0..<3 {
            grid.moveCursor(row: row, column: 0)
            write("abcdef", to: &grid)
        }
        grid.moveCursor(row: 1, column: 2)
        grid.eraseDisplay(.toEnd)

        #expect(grid[0, 5].scalar == 0x66)
        #expect(grid[1, 1].scalar == 0x62)
        #expect(grid[1, 2] == .blank)
        #expect(grid.line(2).isEmpty)
    }

    @Test("erase display to start clears everything above and left")
    func eraseDisplayToStart() {
        var grid = Grid(rows: 3, columns: 6)
        for row in 0..<3 {
            grid.moveCursor(row: row, column: 0)
            write("abcdef", to: &grid)
        }
        grid.moveCursor(row: 1, column: 2)
        grid.eraseDisplay(.toStart)

        #expect(grid.line(0).isEmpty)
        #expect(grid[1, 2] == .blank)
        #expect(grid[1, 3].scalar == 0x64)
        #expect(grid[2, 0].scalar == 0x61)
    }

    @Test("erase display all clears the screen and leaves the cursor")
    func eraseDisplayAll() {
        var grid = Grid(rows: 3, columns: 6)
        for row in 0..<3 {
            grid.moveCursor(row: row, column: 0)
            write("abcdef", to: &grid)
        }
        grid.moveCursor(row: 1, column: 2)
        grid.eraseDisplay(.all)

        for row in 0..<3 { #expect(grid.line(row).isEmpty) }
        #expect(grid.cursor == Cursor(row: 1, column: 2))
    }

    /// Erasing to the end of a row means it no longer continues onto the
    /// next one.
    @Test("erasing the tail of a row clears its wrap flag")
    func erasingClearsTheWrapFlag() {
        var grid = Grid(rows: 3, columns: 4)
        write("abcde", to: &grid)
        #expect(grid.line(0).wrapped)

        grid.moveCursor(row: 0, column: 2)
        grid.eraseLine(.toEnd)
        #expect(!grid.line(0).wrapped)
    }

    /// Shrinking used to `removeLast`, which threw away the rows the cursor
    /// and the newest output were on — and threw them away silently, since
    /// they never reached the scrollback either. Making a window smaller ate
    /// the last commands you had run.
    @Test func shrinkingRowsScrollsIntoScrollbackInsteadOfTruncating() {
        var grid = Grid(rows: 5, columns: 10, scrollbackLimit: 100)
        for line in 1...5 {
            grid.write(UInt32(48 + line))   // "1" ... "5"
            if line < 5 { grid.lineFeed() }
        }
        #expect(grid.cursor.row == 4)

        grid.resize(rows: 3, columns: 10)

        // The newest row survives and the cursor is still on it.
        #expect(grid.rows == 3)
        #expect(grid.cursor.row == 2)
        // `lineFeed` moves down without returning to column 0, so row n
        // holds its digit at column n.
        #expect(grid.line(2)[4].scalar == 53)   // "5", from old row 4
        // The rows that came off the top went to history, not to nothing.
        #expect(grid.scrollback.count == 2)
        #expect(grid.scrollback[0][0].scalar == 49)   // "1", old row 0
        #expect(grid.scrollback[1][1].scalar == 50)   // "2", old row 1
    }

}
