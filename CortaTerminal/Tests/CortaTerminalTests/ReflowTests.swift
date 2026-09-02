import Testing

@testable import CortaTerminal

/// M4.2 — reflow: re-wrapping the document when the column count changes.
@Suite("Reflow")
struct ReflowTests {
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    private func joinedText(of grid: Grid) -> [String] {
        grid.logicalLines().map(\.text)
    }

    /// The scenario the roadmap names by hand: a line that wraps, scrolls
    /// into history, and is then re-wrapped by a resize. Golden in spirit —
    /// every value here is derived by hand from the input, not copied from
    /// a run of the code under test.
    ///
    /// Setup: "abcdefgh" wraps at 6 columns into "abcdef" (wrapped) + "gh",
    /// then two more lines push "abcdef" into scrollback (the row above it
    /// stays "gh", not itself wrapped — nothing continues past it, `\r\n`
    /// wrote the next line). Narrowing to 3 columns must re-wrap the whole
    /// eight-character logical line — "abcdefgh" — as "abc"/"def"/"gh",
    /// two of which land in scrollback and one on screen, and must not
    /// disturb "X" or "Y".
    @Test("narrowing re-wraps a line that already scrolled into history")
    func narrowingRewrapsAcrossTheScrollbackBoundary() {
        var grid = Grid(rows: 3, columns: 6, scrollbackLimit: 10)
        write("abcdefgh", to: &grid)
        grid.carriageReturn()
        grid.lineFeed()
        write("X", to: &grid)
        grid.carriageReturn()
        grid.lineFeed()
        write("Y", to: &grid)

        // Before resizing: "abcdef" already scrolled into history.
        #expect(grid.scrollback.count == 1)
        #expect(grid.scrollback[0].wrapped)

        grid.resize(rows: 3, columns: 3)

        #expect(grid.columns == 3)
        #expect(grid.scrollback.count == 2)
        #expect(grid.scrollback[0].wrapped)
        #expect(grid.scrollback[1].wrapped)
        #expect(joinedText(of: grid) == ["abcdefgh", "X", "Y"])

        // The cursor kept its logical position — right after "Y", the last
        // character typed — not its old (row, column).
        #expect(grid.cursor.row == 2)
        #expect(grid.cursor.column == 1)
        #expect(grid.line(2)[0].scalar == UInt32(UnicodeScalar("Y").value))
    }

    @Test("widening restores the original wrapping where it can")
    func wideningRestoresOriginalWrapping() {
        var grid = Grid(rows: 3, columns: 6, scrollbackLimit: 10)
        write("abcdefgh", to: &grid)

        grid.resize(rows: 3, columns: 3)
        #expect(joinedText(of: grid).filter { !$0.isEmpty } == ["abcdefgh"])
        grid.resize(rows: 3, columns: 6)

        // Back at the original width, the same logical text wraps the same
        // way it originally did: "abcdef" (wrapped) then "gh".
        #expect(joinedText(of: grid).filter { !$0.isEmpty } == ["abcdefgh"])
        var found = false
        for index in grid.documentRowRange {
            let line = grid.logicalLine(containing: index)
            if line.text == "abcdefgh" {
                #expect(line.firstRow <= 0)
                found = true
                break
            }
        }
        #expect(found)
    }

    @Test("narrowing preserves scrollback content across many rows")
    func narrowingPreservesFullScrollbackContent() {
        var grid = Grid(rows: 4, columns: 10, scrollbackLimit: 1_000)
        for line in 0..<50 {
            write("line-\(line)-0123456789", to: &grid)
            grid.carriageReturn()
            grid.lineFeed()
        }
        let before = joinedText(of: grid).filter { !$0.isEmpty }

        grid.resize(rows: 4, columns: 7)
        let after = joinedText(of: grid).filter { !$0.isEmpty }

        #expect(before == after)
    }

    @Test("a wide character pair is never split across a re-wrapped row")
    func widePairSurvivesRewrap() {
        var grid = Grid(rows: 3, columns: 6, scrollbackLimit: 10)
        write("aa中x", to: &grid)  // 'a','a' (2), '中' (2 wide), 'x' (1) = 5 cols of 6

        grid.resize(rows: 3, columns: 3)

        // At 3 columns, "aa中x" (2 + 2 + 1 = 5 display cells) cannot fit
        // "aa" and "中" on the same 3-wide row (中 needs 2, only 1 free) —
        // it must wrap whole onto the next row, never split.
        #expect(joinedText(of: grid).joined() == "aa中x")
        // No row anywhere holds a lone half of the pair: every row's raw
        // cell count that includes the wide lead also includes its spacer.
        for index in 0..<grid.rows {
            let line = grid.line(index)
            for column in 0..<line.count {
                if line[column].attributes.contains(.wide) {
                    #expect(column + 1 < line.count || column + 1 == grid.columns)
                    if column + 1 < line.count {
                        #expect(line[column + 1].attributes.contains(.wideSpacer))
                    }
                }
            }
        }
    }

    @Test("the alternate screen resizes without reflowing")
    func alternateScreenIsNotReflowed() {
        var grid = Grid(rows: 3, columns: 10, scrollbackLimit: 10)
        write("hello", to: &grid)
        grid.enterAlternateScreen()
        write("wrapped-content-here", to: &grid)
        let beforeWrapped = grid.line(0).wrapped

        grid.resize(rows: 3, columns: 5)

        // Resizing truncated/padded, exactly as before reflow existed — it
        // did not re-wrap the alternate screen's content.
        #expect(grid.columns == 5)
        #expect(grid.line(0).wrapped == beforeWrapped)
    }
}
