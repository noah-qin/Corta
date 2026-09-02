import Testing

@testable import CortaTerminal

/// M4.6 — URL detection over logical lines: the scheme allowlist, prose
/// punctuation trimming, soft-wrap joining and hit-testing by cell.
@Suite("LinkDetection")
struct LinkDetectionTests {
    private func terminal(columns: Int = 40, feeding text: String) -> Terminal {
        var terminal = Terminal(rows: 5, columns: columns)
        terminal.feed(Array(text.utf8))
        return terminal
    }

    @Test("an https URL is found with its exact span")
    func plainURL() {
        let terminal = self.terminal(feeding: "see https://example.com/x now")
        let grid = terminal.grid
        let link = LinkDetection.link(at: SelectionPoint(row: 0, column: 10), in: grid)
        #expect(link?.url == "https://example.com/x")
        #expect(link?.range.start == SelectionPoint(row: 0, column: 4))
        #expect(link?.range.end == SelectionPoint(row: 0, column: 4 + 21 - 1))
    }

    @Test("only http, https and mailto can match")
    func schemeAllowlist() {
        let terminal = self.terminal(feeding: "file:///etc/passwd and ftp://x.y")
        let grid = terminal.grid
        // file:// at column 0, ftp:// at column 25 — neither may detect.
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 2), in: grid) == nil)
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 27), in: grid) == nil)

        let mail = self.terminal(feeding: "mailto:a@b.c")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 3), in: mail.grid)?.url
                == "mailto:a@b.c")
    }

    @Test("sentence punctuation is not part of the URL")
    func trailingPunctuation() {
        let terminal = self.terminal(feeding: "see https://example.com/a.")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 5), in: terminal.grid)?.url
                == "https://example.com/a")
    }

    @Test("an unbalanced closing paren is prose, a balanced one is content")
    func parenBalance() {
        let prose = self.terminal(feeding: "(see https://example.com/a)")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 6), in: prose.grid)?.url
                == "https://example.com/a")
        let wiki = self.terminal(feeding: "https://x.y/Foo_(bar)")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 2), in: wiki.grid)?.url
                == "https://x.y/Foo_(bar)")
    }

    @Test("a URL split by a soft wrap is found whole")
    func softWrappedURL() {
        // The URL starts at column 32 of 40 and wraps mid-token.
        let terminal = self.terminal(feeding: String(repeating: "x", count: 32) + "https://example.com/long")
        let grid = terminal.grid
        let link = LinkDetection.link(at: SelectionPoint(row: 1, column: 3), in: grid)
        #expect(link?.url == "https://example.com/long")
        #expect(link?.range.start == SelectionPoint(row: 0, column: 32))
        #expect(link?.range.end == SelectionPoint(row: 1, column: 32 + 24 - 40 - 1))
    }

    @Test("a click outside any URL finds nothing")
    func misses() {
        let terminal = self.terminal(feeding: "see https://example.com now")
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 0), in: terminal.grid) == nil)
        #expect(LinkDetection.link(at: SelectionPoint(row: 1, column: 0), in: terminal.grid) == nil)
    }
}
