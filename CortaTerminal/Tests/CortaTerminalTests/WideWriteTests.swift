import Testing

@testable import CortaTerminal

/// M2.1 integration — `displayWidth` wired into the grid write path. The
/// table itself is covered by `CharacterWidthTests`; these tests cover what
/// the grid does with the widths (wcwidth/xterm conventions, cited per test).
@Suite("Wide and zero-width writes")
struct WideWriteTests {
    /// 中 — U+4E2D, EastAsianWidth W.
    static let wide: UInt32 = 0x4E2D
    /// U+0301 combining acute accent — general category Mn.
    static let combining: UInt32 = 0x301

    @Test("a wide scalar occupies a lead and a spacer, cursor advances two")
    func widePair() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        #expect(grid[0, 0].scalar == Self.wide)
        #expect(grid[0, 0].attributes.contains(.wide))
        #expect(grid[0, 1].attributes.contains(.wideSpacer))
        #expect(grid[0, 1].scalar == 0x20)
        #expect(grid.cursor == Cursor(row: 0, column: 2))
    }

    /// A pair may not straddle the right margin: with one column left, xterm
    /// blanks the column and wraps, landing the pair intact on the next row.
    @Test("a wide scalar at the last column wraps to the next row")
    func wideAtRightMargin() {
        var grid = Grid(rows: 3, columns: 5)
        for _ in 0..<4 { grid.write(0x61) }  // "aaaa", cursor on the last column
        grid.write(Self.wide)
        #expect(grid[0, 4].isBlank)
        #expect(grid.line(0).wrapped)
        #expect(grid[1, 0].scalar == Self.wide)
        #expect(grid[1, 1].attributes.contains(.wideSpacer))
        #expect(grid.cursor == Cursor(row: 1, column: 2))
    }

    /// A pair ending exactly in the last column arms the deferred wrap, with
    /// the cursor resting on the spacer — the same rule as a narrow write.
    @Test("a wide pair filling the last column arms the wrap")
    func widePairArmsWrap() {
        var grid = Grid(rows: 3, columns: 4)
        grid.write(Self.wide)
        grid.write(Self.wide)
        #expect(grid.cursor == Cursor(row: 0, column: 3))
        #expect(grid.pendingWrap)
        grid.write(0x61)
        #expect(grid.line(0).wrapped)
        #expect(grid[1, 0].scalar == 0x61)
    }

    @Test("a combining mark joins the previous cell and does not advance")
    func combiningMark() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(0x65)  // e
        grid.write(Self.combining)
        #expect(grid.cursor == Cursor(row: 0, column: 1))
        let cell = grid[0, 0]
        #expect(cell.scalar == 0x65)
        #expect(grid.graphemes.scalars(for: cell.grapheme) == [0x65, Self.combining])
    }

    /// A mark after a wide pair belongs to the pair's lead cell, not the
    /// spacer the cursor's predecessor column points at.
    @Test("a combining mark after a wide pair joins the lead cell")
    func combiningAfterWide() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        grid.write(Self.combining)
        #expect(grid.cursor == Cursor(row: 0, column: 2))
        #expect(grid.graphemes.scalars(for: grid[0, 0].grapheme) == [Self.wide, Self.combining])
    }

    /// With no previous cell, xterm keeps the mark visible by storing it as
    /// a base character of its own (charproc.c) rather than dropping it.
    @Test("a leading combining mark becomes its own cell")
    func leadingCombiningMark() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.combining)
        #expect(grid[0, 0].scalar == Self.combining)
        #expect(grid.cursor == Cursor(row: 0, column: 1))
    }

    /// Standard behaviour: overwriting either half of a pair blanks BOTH
    /// halves — a dangling half would draw as a stray glyph or blank.
    @Test("overwriting a spacer blanks the whole pair")
    func overwriteSpacer() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        grid.moveCursor(row: 0, column: 1)
        grid.write(0x62)  // b onto the spacer
        #expect(grid[0, 0].isBlank)
        #expect(grid[0, 1].scalar == 0x62)
        #expect(!grid[0, 1].attributes.contains(.wideSpacer))
    }

    @Test("overwriting a lead blanks the whole pair")
    func overwriteLead() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        grid.moveCursor(row: 0, column: 0)
        grid.write(0x62)
        #expect(grid[0, 1].isBlank)
        #expect(grid[0, 0].scalar == 0x62)
    }

    @Test("erasing the line over a pair leaves no halves")
    func eraseOverPair() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        grid.eraseLine(.all)
        #expect(grid[0, 0].isBlank)
        #expect(grid[0, 1].isBlank)
    }

    /// DCH can split a pair across the edit boundary; the surviving half is
    /// blanked by the repair pass rather than left dangling.
    @Test("deleting a pair's lead blanks its spacer")
    func deleteSplitsPair() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(Self.wide)
        grid.write(0x61)
        grid.moveCursor(row: 0, column: 0)
        grid.deleteCharacters(1)  // removes the lead, spacer shifts into view
        #expect(grid[0, 0].isBlank)
        #expect(grid[0, 1].scalar == 0x61)
    }
}
