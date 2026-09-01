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
}
