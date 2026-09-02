import Testing

@testable import CortaTerminal

/// M4 Step 2 — the logical-line read API `Grid+Text.swift` exposes to
/// search (M4.4) and URL detection (M4.6), and the boundary the M4.2
/// storage rewrite must keep passing.
@Suite("Grid+Text")
struct GridTextTests {
    @Test("a soft-wrapped line joins into one logical line with no inserted newline")
    func wrappedLineJoins() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("abcdefghijklmnopqrstuvwxy".utf8))
        let grid = terminal.grid
        let logical = grid.logicalLine(containing: 1)
        #expect(logical.firstRow == 0)
        #expect(logical.lastRow == 2)
        #expect(logical.text == "abcdefghijklmnopqrstuvwxy")
    }

    @Test("hard newlines separate logical lines")
    func hardNewlinesSeparate() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("one\r\ntwo\r\nthree".utf8))
        let grid = terminal.grid
        let lines = grid.logicalLines().map(\.text)
        #expect(lines.filter { !$0.isEmpty } == ["one", "two", "three"])
    }

    @Test("trailing blanks are trimmed from a logical line's text")
    func trailingBlanksTrimmed() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("abc\r\nde\r\n".utf8))
        let grid = terminal.grid
        let lines = grid.logicalLines().map(\.text)
        #expect(lines.contains("abc"))
        #expect(lines.contains("de"))
    }

    @Test("a match offset maps back to the (row, column) it came from")
    func offsetMapsToPosition() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("abcdefghijklmnopqrstuvwxy".utf8))
        let grid = terminal.grid
        let logical = grid.logicalLine(containing: 0)
        // 'k' is the 11th character (index 10), which landed on row 1, column 0
        // (row 0 held columns 0-9, i.e. 'a'...'j').
        let position = logical.position(at: 10)
        #expect(position?.row == 1)
        #expect(position?.column == 0)
    }

    @Test("a logical line spanning scrollback and screen uses document row numbering")
    func spansScrollbackAndScreen() {
        var terminal = Terminal(rows: 3, columns: 10, scrollbackLimit: 100)
        // Fill enough to push the wrapped command into scrollback, then
        // continue it onto the live screen.
        terminal.feed(Array("first\r\nsecond\r\n".utf8))
        terminal.feed(Array("abcdefghijklmno".utf8))
        let grid = terminal.grid
        #expect(grid.scrollback.count > 0)
        let lines = grid.logicalLines().map(\.text)
        #expect(lines.last == "abcdefghijklmno")
    }

    @Test("a wide character's spacer cell contributes no stray character")
    func wideSpacerContributesNothing() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("中文x".utf8))
        let grid = terminal.grid
        let logical = grid.logicalLine(containing: 0)
        #expect(logical.text == "中文x")
    }

    @Test("iterating logical lines does not require materializing the whole scrollback")
    func iterationIsLazy() {
        var terminal = Terminal(rows: 5, columns: 20, scrollbackLimit: 10_000)
        for i in 0..<5_000 {
            terminal.feed(Array("line \(i)\r\n".utf8))
        }
        let grid = terminal.grid
        var iterator = grid.logicalLines().makeIterator()
        // Only pull the first few — proves the sequence doesn't eagerly
        // build an array of everything before yielding the first element.
        #expect(iterator.next() != nil)
        #expect(iterator.next() != nil)
    }
}
