import Testing

@testable import CortaTerminal

/// M2.4 — the scroll region (DECSTBM), driven through the grid API.
@Suite("Scroll region")
struct ScrollRegionTests {
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    @Test("a new grid scrolls the whole screen")
    func defaultRegionIsTheWholeScreen() {
        let grid = Grid(rows: 4, columns: 8)
        #expect(grid.marginTop == 0)
        #expect(grid.marginBottom == 3)
    }

    /// VT510 §DECSTBM: setting the region homes the cursor.
    @Test("setting the region homes the cursor")
    func settingTheRegionHomesTheCursor() {
        var grid = Grid(rows: 6, columns: 8)
        grid.moveCursor(row: 5, column: 4)
        grid.setScrollRegion(top: 1, bottom: 4)
        #expect(grid.marginTop == 1)
        #expect(grid.marginBottom == 4)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
    }

    /// VT510 §DECSTBM: a region is at least two rows; a request whose top is
    /// not above its bottom is ignored, margins unchanged.
    @Test("an invalid region is ignored")
    func invalidRegionIsIgnored() {
        var grid = Grid(rows: 6, columns: 8)
        grid.setScrollRegion(top: 3, bottom: 3)
        #expect(grid.marginTop == 0)
        #expect(grid.marginBottom == 5)
        grid.setScrollRegion(top: 4, bottom: 2)
        #expect(grid.marginTop == 0)
        #expect(grid.marginBottom == 5)
        // The cursor is not homed by an ignored request.
    }

    /// The bottom margin is clamped to the screen, per the one-based wire
    /// form `CSI 2 ; 999 r` meaning "from row 2 to the end".
    @Test("an oversized bottom margin clamps to the screen")
    func bottomMarginClamps() {
        var grid = Grid(rows: 6, columns: 8)
        grid.setScrollRegion(top: 1, bottom: 999)
        #expect(grid.marginTop == 1)
        #expect(grid.marginBottom == 5)
    }

    /// VT100 User Guide, "Scrolling Region": a line feed at the bottom
    /// margin scrolls only within the margins.
    @Test("a line feed at the bottom margin scrolls within the region")
    func lineFeedScrollsWithinTheRegion() {
        var grid = Grid(rows: 5, columns: 8)
        write("top", to: &grid)
        grid.moveCursor(row: 4, column: 0)
        write("bot", to: &grid)
        grid.setScrollRegion(top: 1, bottom: 3)
        for row in 1...3 {
            grid.moveCursor(row: row, column: 0)
            write(["aa", "bb", "cc"][row - 1], to: &grid)
        }
        grid.moveCursor(row: 3, column: 0)

        grid.lineFeed()  // scrolls rows 1...3 up by one, discarding "aa"

        #expect(grid[0, 0].scalar == 0x74)  // "top" untouched
        #expect(grid[4, 0].scalar == 0x62)  // "bot" untouched
        #expect(grid[1, 0].scalar == 0x62)  // "bb" moved up a row
        #expect(grid[2, 0].scalar == 0x63)  // "cc" moved up a row
        #expect(grid.line(3).isEmpty)       // blank row opened at the margin
        #expect(grid.cursor.row == 3)
        #expect(grid.scrollback.isEmpty)
    }

    /// With a partial region, scrolled-off rows are an application's
    /// transient content, not the user's history.
    @Test("a partial region never writes the scrollback")
    func partialRegionSkipsTheScrollback() {
        var grid = Grid(rows: 4, columns: 8)
        grid.setScrollRegion(top: 0, bottom: 2)
        for _ in 0..<10 { grid.scrollUp(1) }
        #expect(grid.scrollback.isEmpty)
    }

    /// A line feed below the bottom margin moves down to the last row and
    /// then stops — it does not scroll.
    @Test("a line feed below the region does not scroll")
    func lineFeedBelowTheRegionDoesNotScroll() {
        var grid = Grid(rows: 4, columns: 8)
        write("one", to: &grid)
        grid.setScrollRegion(top: 0, bottom: 1)
        grid.moveCursor(row: 3, column: 0)
        grid.lineFeed()
        #expect(grid.cursor.row == 3)
        #expect(grid[0, 0].scalar == 0x6F)  // "one" still there
        #expect(grid.scrollback.isEmpty)
    }

    /// A full-screen region is the common case: the scrolled-off row is
    /// history.
    @Test("a full-screen region writes the scrollback")
    func fullScreenRegionWritesTheScrollback() {
        var grid = Grid(rows: 3, columns: 8)
        write("one", to: &grid)
        grid.setScrollRegion(top: 0, bottom: 2)
        grid.scrollUp(1)
        #expect(grid.scrollback.count == 1)
    }

    @Test("a resize that shrinks past the margins resets them")
    func resizeResetsMargins() {
        var grid = Grid(rows: 6, columns: 8)
        grid.setScrollRegion(top: 2, bottom: 5)
        grid.resize(rows: 2, columns: 8)
        #expect(grid.marginTop == 0)
        #expect(grid.marginBottom == 1)
    }

    /// The alternate screen starts with full-screen margins; the main
    /// screen's margins are parked with it and come back on exit.
    @Test("the alternate screen has its own full-screen margins")
    func alternateScreenResetsMargins() {
        var grid = Grid(rows: 6, columns: 8)
        grid.setScrollRegion(top: 1, bottom: 4)
        grid.enterAlternateScreen()
        #expect(grid.marginTop == 0)
        #expect(grid.marginBottom == 5)
        grid.exitAlternateScreen()
        #expect(grid.marginTop == 1)
        #expect(grid.marginBottom == 4)
    }

    // MARK: - SU / SD

    /// SD — ECMA-48 §8.3.113: the region shifts down, blank rows open at
    /// the top margin, rows outside the margins stay put.
    @Test("scrolling down opens blank rows at the top margin")
    func scrollDownWithinTheRegion() {
        var grid = Grid(rows: 5, columns: 8)
        write("top", to: &grid)
        grid.moveCursor(row: 4, column: 0)
        write("bot", to: &grid)
        grid.setScrollRegion(top: 1, bottom: 3)
        grid.moveCursor(row: 1, column: 0)
        write("aa", to: &grid)

        grid.scrollDown(2)

        #expect(grid[0, 0].scalar == 0x74)  // "top" untouched
        #expect(grid[3, 0].scalar == 0x61)  // "aa" pushed down two
        #expect(grid.line(1).isEmpty)
        #expect(grid.line(2).isEmpty)
        #expect(grid[4, 0].scalar == 0x62)  // "bot" untouched
        #expect(grid.scrollback.isEmpty)
    }

    /// SU/SD by the region's whole height blanks the region.
    @Test("scrolling by the region's height blanks it")
    func scrollingByTheRegionHeightBlanksIt() {
        var grid = Grid(rows: 4, columns: 8)
        for row in 1...2 {
            grid.moveCursor(row: row, column: 0)
            write("xx", to: &grid)
        }
        grid.setScrollRegion(top: 1, bottom: 2)
        grid.scrollUp(2)
        #expect(grid.line(1).isEmpty)
        #expect(grid.line(2).isEmpty)
        grid.scrollDown(99)  // clamped, not a crash
        #expect(grid.line(1).isEmpty)
        #expect(grid.line(2).isEmpty)
    }
}
