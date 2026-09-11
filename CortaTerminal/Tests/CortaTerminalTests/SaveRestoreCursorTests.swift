import Testing

@testable import CortaTerminal

/// M2.5 — DECSC/DECRC, driven through the grid API. The wire form
/// (`ESC 7` / `ESC 8`) is covered by the `save-restore-cursor` golden.
@Suite("Save and restore cursor")
struct SaveRestoreCursorTests {
    /// VT510 §DECSC / §DECRC: position and rendition are saved and restored.
    @Test("restore brings back the position and the pen")
    func restoreBringsBackPositionAndPen() {
        var grid = Grid(rows: 4, columns: 10)
        grid.moveCursor(row: 2, column: 5)
        grid.pen.foreground = .indexed(3)
        grid.saveCursor()

        grid.moveCursor(row: 0, column: 0)
        grid.pen.reset()
        grid.restoreCursor()

        #expect(grid.cursor == Cursor(row: 2, column: 5))
        #expect(grid.pen.foreground == .indexed(3))
    }

    /// The saved position may no longer fit after a resize; restoring clamps
    /// it onto the screen rather than trapping.
    @Test("a restored cursor is clamped to the current screen")
    func restoreClamps() {
        var grid = Grid(rows: 4, columns: 10)
        grid.moveCursor(row: 3, column: 9)
        grid.saveCursor()
        grid.resize(rows: 2, columns: 4)
        grid.restoreCursor()
        #expect(grid.cursor == Cursor(row: 1, column: 3))
    }

    /// VT510 §DECRC: with nothing saved, the factory settings come back —
    /// home position and the default rendition.
    @Test("restoring with nothing saved homes and resets")
    func restoreWithoutSaveResets() {
        var grid = Grid(rows: 4, columns: 10)
        grid.moveCursor(row: 2, column: 5)
        grid.pen.attributes = .bold
        grid.restoreCursor()
        #expect(grid.cursor == Cursor(row: 0, column: 0))
        #expect(grid.pen == Pen())
    }

    /// The pending-wrap state is part of the saved cursor: printing after a
    /// restore continues exactly where the saved printing left off.
    @Test("the pending wrap is saved with the cursor")
    func pendingWrapIsSaved() {
        var grid = Grid(rows: 4, columns: 4)
        for scalar in "abcd".unicodeScalars { grid.write(scalar.value) }
        #expect(grid.pendingWrap)
        grid.saveCursor()
        grid.moveCursor(row: 2, column: 0)
        grid.restoreCursor()
        #expect(grid.pendingWrap)
        #expect(grid.cursor == Cursor(row: 0, column: 3))
    }

    // MARK: - SCOSC / SCORC (B06)

    /// `CSI s` / `CSI u` (ANSI.SYS SCOSC/SCORC), wired as aliases for
    /// DECSC/DECRC since Corta has no DECLRMM margin mode to disambiguate
    /// against — the same fallback xterm uses. Fed through `Terminal`, not
    /// `Grid` directly, since what is under test is the wire form reaching
    /// `Grid.saveCursor()`/`restoreCursor()` at all.
    @Test("CSI s / CSI u alias DECSC/DECRC")
    func csiSaveRestoreAliasesDECSC() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("\u{1B}[2;6H\u{1B}[s".utf8))  // move to (row 2, col 6), save
        terminal.feed(Array("\u{1B}[1;1H\u{1B}[u".utf8))  // move home, then restore
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 5))
    }

    /// Bare `CSI u` (no private marker) must not be confused with the kitty
    /// keyboard protocol's `CSI ? u` / `CSI = u` / `CSI &lt; u` / `CSI &gt; u`,
    /// which all carry a marker and are a completely different sequence
    /// family that happens to share the final byte.
    @Test("bare CSI u does not disturb the kitty keyboard protocol stack")
    func bareCSIuDoesNotTouchKittyProtocol() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("\u{1B}[=5u".utf8))  // set kitty flags
        let flagsBeforeBareU = terminal.keyboardEnhancements
        terminal.feed(Array("\u{1B}[u".utf8))  // SCORC, not a kitty query
        #expect(terminal.keyboardEnhancements == flagsBeforeBareU)
    }

    /// The kitty keyboard protocol's own key-report form — `CSI
    /// code;modifiers u`, unmarked but parameterized — must not be
    /// misread as SCORC: it carries no private marker, so only the
    /// parameter count tells it apart from a bare `CSI u`.
    @Test("a parameterized CSI u (a kitty key report) does not restore the cursor")
    func parameterizedCSIuIsNotSCORC() {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("\u{1B}[2;6H\u{1B}[s".utf8))  // move to (row 2, col 6), save
        terminal.feed(Array("\u{1B}[1;1H".utf8))  // move home
        terminal.feed(Array("\u{1B}[97;5u".utf8))  // an echoed kitty key report, not SCORC
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 0))
    }
}
