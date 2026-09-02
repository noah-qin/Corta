import Testing

@testable import CortaTerminal

/// M4.4 — scrollback search: case-insensitive by default, matches over
/// logical lines so a wrap boundary doesn't split a match.
@Suite("Search")
struct SearchTests {
    @Test("finds a plain match on one row")
    func plainMatch() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello world".utf8))
        let matches = Search.find("world", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start == SelectionPoint(row: 0, column: 6))
        #expect(matches[0].end == SelectionPoint(row: 0, column: 10))
    }

    @Test("is case-insensitive by default")
    func caseInsensitiveByDefault() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("Hello World".utf8))
        #expect(Search.find("world", in: terminal.grid).count == 1)
        #expect(Search.find("WORLD", in: terminal.grid).count == 1)
    }

    @Test("case-sensitive search excludes a differently-cased match")
    func caseSensitiveOptIn() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("Hello World".utf8))
        #expect(Search.find("world", in: terminal.grid, caseSensitive: true).isEmpty)
        #expect(Search.find("World", in: terminal.grid, caseSensitive: true).count == 1)
    }

    @Test("a match spanning a soft wrap is found whole")
    func matchSpansSoftWrap() {
        var terminal = Terminal(rows: 5, columns: 8)
        // "abcdefgh" wraps into "abcdefgh" over two rows at 8 columns... use
        // a query that straddles the wrap boundary.
        terminal.feed(Array("1234567890".utf8))  // wraps at column 8: "12345678"/"90"
        let matches = Search.find("7890", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start == SelectionPoint(row: 0, column: 6))
        #expect(matches[0].end == SelectionPoint(row: 1, column: 1))
    }

    @Test("finds multiple matches on the same logical line")
    func multipleMatchesOnOneLine() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("cat and cat and cat".utf8))
        let matches = Search.find("cat", in: terminal.grid)
        #expect(matches.count == 3)
    }

    @Test("finds a match already in scrollback")
    func matchInScrollback() {
        var terminal = Terminal(rows: 2, columns: 20, scrollbackLimit: 10)
        terminal.feed(Array("findme\r\nsecond\r\nthird".utf8))
        #expect(terminal.grid.scrollback.count >= 1)
        let matches = Search.find("findme", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start.row < 0)
    }

    @Test("an empty query matches nothing")
    func emptyQueryMatchesNothing() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello".utf8))
        #expect(Search.find("", in: terminal.grid).isEmpty)
    }

    @Test("no match returns an empty array without trapping")
    func noMatch() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello".utf8))
        #expect(Search.find("goodbye", in: terminal.grid).isEmpty)
    }
}
