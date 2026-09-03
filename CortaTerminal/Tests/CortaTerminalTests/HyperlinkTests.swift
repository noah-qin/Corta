import Testing

@testable import CortaTerminal

/// M6.8 — OSC 8 hyperlinks: the case where the text on screen and the
/// destination differ, which is the whole reason `SECURITY.md` §2.4 says to
/// show the real target.
@Suite("OSC 8 hyperlinks")
struct HyperlinkTests {
    private func terminal(feeding input: String) -> Terminal {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array(input.utf8))
        return terminal
    }

    @Test("cells written inside OSC 8 carry the link, cells after it do not")
    func linkAppliesToTheCellsBetween() {
        let terminal = terminal(
            feeding: "\u{1B}]8;;https://example.com\u{1B}\\click\u{1B}]8;;\u{1B}\\ plain")
        let grid = terminal.grid
        let id = grid.line(0)[0].hyperlink
        #expect(!id.isNone)
        #expect(grid.hyperlinks.url(for: id) == "https://example.com")
        for column in 0..<5 { #expect(grid.line(0)[column].hyperlink == id) }
        // The space and "plain" come after the closing OSC 8.
        for column in 5..<11 { #expect(grid.line(0)[column].hyperlink.isNone) }
    }

    @Test("the display text and the destination are allowed to differ")
    func textAndTargetDiffer() {
        let terminal = terminal(
            feeding: "\u{1B}]8;;https://example.com/real\u{1B}\\https://decoy.test\u{1B}]8;;\u{1B}\\")
        let point = SelectionPoint(row: 0, column: 3)
        let link = LinkDetection.link(at: point, in: terminal.grid)
        // Pattern detection would find the decoy in the text; the explicit
        // link has to win, or ⌘-click opens what the text says instead of
        // what the program said.
        #expect(link?.url == "https://example.com/real")
    }

    @Test("the id parameter is parsed and ignored")
    func idParameterIsIgnored() {
        let terminal = terminal(feeding: "\u{1B}]8;id=xyz;https://example.com\u{1B}\\ab")
        let id = terminal.grid.line(0)[0].hyperlink
        #expect(terminal.grid.hyperlinks.url(for: id) == "https://example.com")
    }

    @Test("identical targets intern to one entry")
    func targetsAreInterned() {
        let terminal = terminal(
            feeding: "\u{1B}]8;;https://a.test\u{1B}\\a\u{1B}]8;;\u{1B}\\"
                + "\u{1B}]8;;https://a.test\u{1B}\\b\u{1B}]8;;\u{1B}\\")
        #expect(terminal.grid.hyperlinks.count == 1)
        #expect(terminal.grid.line(0)[0].hyperlink == terminal.grid.line(0)[1].hyperlink)
    }

    @Test("SGR 0 does not end a hyperlink")
    func resetDoesNotEndTheLink() {
        // A program that colours its link text and then resets has not
        // stopped linking; only `OSC 8 ; ; ST` does that.
        let terminal = terminal(
            feeding: "\u{1B}]8;;https://a.test\u{1B}\\\u{1B}[31ma\u{1B}[0mb")
        #expect(!terminal.grid.line(0)[1].hyperlink.isNone)
    }

    @Test("an over-long target is refused and leaves the text unlinked")
    func overLongTargetIsRefused() {
        let long = String(repeating: "x", count: HyperlinkTable.maximumURLLength + 1)
        let terminal = terminal(feeding: "\u{1B}]8;;https://\(long)\u{1B}\\ab")
        #expect(terminal.grid.line(0)[0].hyperlink.isNone)
        #expect(terminal.grid.hyperlinks.count == 0)
    }

    @Test("a full table leaves later links unlinked rather than reusing an id")
    func fullTableFailsClosed() {
        var table = HyperlinkTable()
        for index in 0..<HyperlinkTable.capacity {
            #expect(table.intern("https://example.test/\(index)") != nil)
        }
        #expect(table.intern("https://one.too.many") == nil)
    }

    /// The packing this feature is built on: the id shares a word with the
    /// scalar, so a cell that carries both must still report both.
    @Test("a cell packs a full-codespace scalar alongside a hyperlink id")
    func scalarAndLinkCoexist() {
        var cell = Cell(scalar: 0x10FFFF, hyperlink: HyperlinkID(rawValue: 2047))
        #expect(cell.scalar == 0x10FFFF)
        #expect(cell.hyperlink.rawValue == 2047)
        cell.scalar = 0x41
        #expect(cell.hyperlink.rawValue == 2047)
        cell.hyperlink = .none
        #expect(cell.scalar == 0x41)
    }
}
