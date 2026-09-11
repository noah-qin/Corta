import Testing

@testable import CortaTerminal

/// M2.3 — the alternate screen (`?1049`), driven through the grid API.
@Suite("Alternate screen")
struct AlternateScreenTests {
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    /// xterm ctlseqs, Ps = 1049: on set — save cursor, switch to the
    /// alternate screen, clear it.
    @Test("entering switches to a fresh blank screen and homes the cursor")
    func enteringSwitchesToABlankScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.moveCursor(row: 2, column: 5)

        grid.enterAlternateScreen()

        #expect(grid.isAlternateScreenActive)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
        for row in 0..<3 { #expect(grid.line(row).isEmpty) }
    }

    /// xterm ctlseqs, Ps = 1049: on reset — switch back and restore the
    /// cursor saved on the way in.
    @Test("exiting restores the main screen and the saved cursor")
    func exitingRestoresMainScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.moveCursor(row: 2, column: 5)

        grid.enterAlternateScreen()
        write("ALT", to: &grid)
        grid.exitAlternateScreen()

        #expect(!grid.isAlternateScreenActive)
        #expect(grid.cursor == Cursor(row: 2, column: 5))
        #expect(grid[0, 0].scalar == 0x6D)  // "m"
        #expect(grid[0, 3].scalar == 0x6E)  // "n"
        #expect(grid.line(1).isEmpty)
    }

    /// A private mode set by the program is terminal-wide state, not part
    /// of either screen's own content — `exitAlternateScreen` restores the
    /// parked main screen wholesale, and without carrying the mode across
    /// explicitly (the same way `cursorStyle` already is) a `?45` a full-
    /// screen child set would be silently discarded on exit (B06).
    @Test("reverse-wraparound mode survives an alternate-screen round trip")
    func reverseWraparoundSurvivesAlternateScreen() {
        var grid = Grid(rows: 3, columns: 8)
        grid.reverseWraparoundEnabled = true

        grid.enterAlternateScreen()
        #expect(grid.reverseWraparoundEnabled)

        grid.exitAlternateScreen()
        #expect(grid.reverseWraparoundEnabled)
    }

    /// The mode can also change *while* the alternate screen is active —
    /// e.g. `tmux` or `less` setting it for their own full-screen UI — and
    /// that value, not whatever the main screen had before entering, is
    /// what must survive the exit.
    @Test("a mode change made while the alternate screen is active survives exiting it")
    func modeChangedDuringAlternateScreenSurvivesExit() {
        var grid = Grid(rows: 3, columns: 8)
        #expect(!grid.reverseWraparoundEnabled)

        grid.enterAlternateScreen()
        grid.reverseWraparoundEnabled = true
        grid.exitAlternateScreen()

        #expect(grid.reverseWraparoundEnabled)
    }

    /// An alternate screen has no history (roadmap M2.3): lines scrolled
    /// while it is live are discarded, not pushed to the main scrollback.
    @Test("the alternate screen has no scrollback")
    func alternateScreenHasNoScrollback() {
        var grid = Grid(rows: 2, columns: 8)
        write("one", to: &grid)
        grid.lineFeed()
        grid.carriageReturn()
        write("two", to: &grid)
        grid.lineFeed()  // "one" enters history
        #expect(grid.scrollback.count == 1)

        grid.enterAlternateScreen()
        for _ in 0..<10 { grid.lineFeed() }  // scrolls on the alt screen
        #expect(grid.scrollback.isEmpty)

        grid.exitAlternateScreen()
        #expect(grid.scrollback.count == 1)
        #expect(grid.scrollback[0][0].scalar == 0x6F)  // "o" of "one"
    }

    /// Exiting without entering, like any unpaired reset, is a no-op.
    @Test("exiting while the main screen is live does nothing")
    func exitingWithoutEnteringIsIgnored() {
        var grid = Grid(rows: 2, columns: 8)
        write("main", to: &grid)
        grid.exitAlternateScreen()
        #expect(!grid.isAlternateScreenActive)
        #expect(grid[0, 0].scalar == 0x6D)
    }

    /// A second `?1049 h` while already active clears again but keeps the
    /// original main screen parked — the first switch is the one that
    /// matters.
    @Test("entering twice parks the main screen once")
    func enteringTwiceParksMainOnce() {
        var grid = Grid(rows: 2, columns: 8)
        write("main", to: &grid)
        grid.enterAlternateScreen()
        write("junk", to: &grid)
        grid.enterAlternateScreen()
        write("more", to: &grid)
        grid.exitAlternateScreen()

        #expect(!grid.isAlternateScreenActive)
        #expect(grid[0, 0].scalar == 0x6D)
        #expect(grid[0, 3].scalar == 0x6E)
    }

    /// The size belongs to the window, not to a screen: a resize while the
    /// alternate screen is live is adopted by the main screen on the way
    /// back.
    @Test("a resize during the alternate screen is adopted on exit")
    func resizeDuringAlternateScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.enterAlternateScreen()
        grid.resize(rows: 2, columns: 4)
        grid.exitAlternateScreen()

        #expect(grid.rows == 2)
        #expect(grid.columns == 4)
        #expect(grid[0, 0].scalar == 0x6D)
    }
}
