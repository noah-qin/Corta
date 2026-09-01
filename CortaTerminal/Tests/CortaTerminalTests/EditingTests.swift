import Testing

@testable import CortaTerminal

/// M2.5 — IL, DL, ICH and DCH, driven through the grid API.
@Suite("Editing operations")
struct EditingTests {
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    /// ECMA-48 §8.3.67: rows below the cursor shift down within the scroll
    /// region; what crosses the bottom margin is lost.
    @Test("inserting lines shifts down within the region")
    func insertLinesShiftsDown() {
        var grid = Grid(rows: 4, columns: 8)
        grid.setScrollRegion(top: 1, bottom: 3)
        for row in 1...3 {
            grid.moveCursor(row: row, column: 0)
            write(["aa", "bb", "cc"][row - 1], to: &grid)
        }
        grid.moveCursor(row: 1, column: 0)
        grid.insertLines(2)

        #expect(grid.line(1).isEmpty)
        #expect(grid.line(2).isEmpty)
        #expect(grid[3, 0].scalar == 0x61)  // "aa" shifted down two
        // "bb" and "cc" fell past the bottom margin.
        #expect(grid.cursor == Cursor(row: 1, column: 0))
    }

    /// ECMA-48 §8.3.32: rows below the cursor shift up within the region;
    /// erased rows open at the bottom margin.
    @Test("deleting lines shifts up within the region")
    func deleteLinesShiftsUp() {
        var grid = Grid(rows: 4, columns: 8)
        grid.setScrollRegion(top: 1, bottom: 3)
        for row in 1...3 {
            grid.moveCursor(row: row, column: 0)
            write(["aa", "bb", "cc"][row - 1], to: &grid)
        }
        grid.moveCursor(row: 1, column: 0)
        grid.deleteLines(1)

        #expect(grid[1, 0].scalar == 0x62)  // "bb"
        #expect(grid[2, 0].scalar == 0x63)  // "cc"
        #expect(grid.line(3).isEmpty)
        #expect(grid.scrollback.isEmpty)
    }

    /// Both are ignored when the cursor is outside the scroll region —
    /// the region is what the operation edits.
    @Test("line editing outside the region is ignored")
    func lineEditingOutsideTheRegionIsIgnored() {
        var grid = Grid(rows: 4, columns: 8)
        grid.setScrollRegion(top: 2, bottom: 3)
        grid.moveCursor(row: 0, column: 0)
        write("aa", to: &grid)
        grid.moveCursor(row: 0, column: 0)
        grid.insertLines(1)
        grid.deleteLines(1)
        #expect(grid[0, 0].scalar == 0x61)
        #expect(grid.line(1).isEmpty)
    }

    @Test("inserting characters shifts the row right and clips at the margin")
    func insertCharactersClips() {
        var grid = Grid(rows: 2, columns: 6)
        write("abcdef", to: &grid)
        grid.moveCursor(row: 0, column: 1)
        grid.insertCharacters(2)

        #expect(grid[0, 0].scalar == 0x61)
        #expect(grid[0, 1] == .blank)
        #expect(grid[0, 2] == .blank)
        #expect(grid[0, 3].scalar == 0x62)  // "b"
        #expect(grid[0, 5].scalar == 0x64)  // "d" — "e" and "f" are gone
        #expect(grid.cursor == Cursor(row: 0, column: 1))
    }

    @Test("deleting characters pulls the tail left and erases the end")
    func deleteCharactersPullsLeft() {
        var grid = Grid(rows: 2, columns: 6)
        write("abcdef", to: &grid)
        grid.moveCursor(row: 0, column: 1)
        grid.deleteCharacters(2)

        #expect(grid[0, 0].scalar == 0x61)
        #expect(grid[0, 1].scalar == 0x64)  // "d"
        #expect(grid[0, 3].scalar == 0x66)  // "f"
        #expect(grid[0, 4] == .blank)
        // The blank erase template keeps the row variable length.
        #expect(grid.line(0).count == 4)
    }

    /// BCE: inserted cells carry the current background, and a row erased
    /// under a colour is stored, not dropped.
    @Test("inserting under a background colour paints it")
    func insertingPaintsTheBackground() {
        var grid = Grid(rows: 2, columns: 6)
        grid.pen.background = .indexed(4)
        grid.insertCharacters(3)
        #expect(grid[0, 2].background == .indexed(4))
        #expect(grid.line(0).count == 6)

        grid.moveCursor(row: 1, column: 0)
        grid.insertLines(1)
        #expect(grid[1, 5].background == .indexed(4))
    }

    /// Inserting into a soft-wrapped row breaks the continuation.
    @Test("editing a wrapped row clears its wrap flag")
    func editingClearsTheWrapFlag() {
        var grid = Grid(rows: 2, columns: 4)
        write("abcde", to: &grid)
        #expect(grid.line(0).wrapped)
        grid.moveCursor(row: 0, column: 1)
        grid.insertCharacters(1)
        #expect(!grid.line(0).wrapped)
    }

    @Test("counts larger than the region are clamped")
    func countsAreClamped() {
        var grid = Grid(rows: 3, columns: 4)
        write("aaa", to: &grid)
        grid.moveCursor(row: 0, column: 0)
        grid.deleteCharacters(999)
        #expect(grid.line(0).isEmpty)
        grid.deleteLines(999)
        grid.insertLines(999)
        for row in 0..<3 { #expect(grid.line(row).isEmpty) }
    }
}
