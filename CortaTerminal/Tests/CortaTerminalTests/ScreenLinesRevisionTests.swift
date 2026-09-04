import Testing

@testable import CortaTerminal

/// M9 — the per-row mutation stamp `TerminalRenderer` reads instead of
/// comparing full `Line` values (`ScreenLines.swift`, `PERFORMANCE.md` §3
/// "On damage tracking"). Driven directly against `Grid`/`ScreenLines`, no
/// parser, no renderer.
@Suite("ScreenLines revision")
struct ScreenLinesRevisionTests {
    @Test("writing a cell bumps only that row's revision")
    func writeBumpsOnlyThatRow() {
        var grid = Grid(rows: 3, columns: 10)
        let before = (0..<3).map { grid.lineRevision($0) }

        grid.moveCursor(row: 1, column: 0)
        grid.write(0x61)

        #expect(grid.lineRevision(0) == before[0])
        #expect(grid.lineRevision(1) != before[1])
        #expect(grid.lineRevision(2) == before[2])
    }

    @Test("writing the same row twice bumps its revision each time")
    func repeatedWritesKeepBumping() {
        var grid = Grid(rows: 2, columns: 10)
        grid.moveCursor(row: 0, column: 0)
        grid.write(0x61)
        let first = grid.lineRevision(0)
        grid.moveCursor(row: 0, column: 0)
        grid.write(0x62)
        let second = grid.lineRevision(0)
        #expect(first != second)
    }

    @Test("a row erased back to blank still gets a fresh revision")
    func eraseBumpsRevisionEvenWhenContentEndsUpTheSame() {
        var grid = Grid(rows: 1, columns: 10)
        let blank = grid.lineRevision(0)
        grid.write(0x61)
        let afterWrite = grid.lineRevision(0)
        grid.eraseLine(.all)
        let afterErase = grid.lineRevision(0)
        // Content round-tripped to blank, but the revision is a mutation
        // stamp, not a content hash — it must not go back to what it was
        // before the write (`ScreenLines.swift`'s doc comment on why
        // conservative-different is the safe direction, never
        // conservative-same).
        #expect(afterWrite != blank)
        #expect(afterErase != afterWrite)
        #expect(afterErase != blank)
    }

    @Test("moving the cursor alone does not bump any row's revision")
    func cursorMotionAloneDoesNotBumpRevisions() {
        var grid = Grid(rows: 3, columns: 10)
        let before = (0..<3).map { grid.lineRevision($0) }
        grid.moveCursor(row: 2, column: 5)
        let after = (0..<3).map { grid.lineRevision($0) }
        #expect(before == after)
    }

    @Test("scrolling stamps the newly exposed row, not the ones that moved")
    func scrollingStampsOnlyTheExposedRow() {
        var grid = Grid(rows: 3, columns: 10)
        grid.write(0x61)  // row 0
        grid.moveCursor(row: 1, column: 0)
        grid.write(0x62)  // row 1
        grid.moveCursor(row: 2, column: 0)
        grid.write(0x63)  // row 2
        let row1Before = grid.lineRevision(1)
        let row2Before = grid.lineRevision(2)

        grid.scrollUp(1)

        // Row 0 is gone (scrolled into history); the old row 1 is now row 0
        // and the old row 2 is now row 1 — `rotateUp` only resets and stamps
        // the row exposed at the bottom, it does not touch the ones that
        // logically shifted (they didn't move in the ring buffer, the
        // window over it did).
        #expect(grid.lineRevision(0) == row1Before)
        #expect(grid.lineRevision(1) == row2Before)
        // The newly exposed bottom row is fresh content (blank) with its own
        // new stamp, not row 2's old one and not left over from row 0.
        #expect(grid.lineRevision(2) != row1Before)
        #expect(grid.lineRevision(2) != row2Before)
    }

    @Test("the revision stamp lives outside Line, not as a field on it")
    func revisionIsNotPartOfLineItself() {
        // The stamp is `ScreenLines`/`Grid.lineRevision(_:)` state, kept
        // deliberately off `Line` itself — adding it as a stored property
        // would change what `Line`'s synthesized `Equatable` compares, and
        // every golden-file/fuzz test that builds an expected `Line` from
        // scratch and compares it against grid output relies on that
        // equality being content-only.
        var grid = Grid(rows: 1, columns: 10)
        grid.write(0x61)
        let expected = Line(wrapped: false, mark: .none, cells: [grid[0, 0]])
        #expect(grid.line(0) == expected)
    }

    @Test("resize replaces the grid, which the row-count check already forces full elsewhere")
    func resizeDoesNotCrashOnRevisionLookup() {
        var grid = Grid(rows: 2, columns: 10)
        grid.write(0x61)
        grid.resize(rows: 4, columns: 10)
        // The point of this test is the absence of a crash/precondition
        // failure reading a revision for a row that only exists after the
        // resize grew `lines` via `ScreenLines.append` — see that method's
        // comment on why the appended rows' stamps don't need to mean
        // anything (`Grid.resize` always changes `rows`, which
        // `TerminalRenderer.updateInstances` already treats as a full
        // rebuild independently of any revision).
        for row in 0..<4 { _ = grid.lineRevision(row) }
    }
}
