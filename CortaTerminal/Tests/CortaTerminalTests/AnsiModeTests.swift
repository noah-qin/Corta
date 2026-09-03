import Testing

@testable import CortaTerminal

/// SM / RM — the ANSI (non-private) modes, `CSI Pm h` / `CSI Pm l`.
///
/// These had no dispatch case at all: only the `?`-marked DECSET/DECRST form
/// was handled, so `CSI 4 h` (insert mode) was parsed, matched nothing, and
/// was dropped — while DECRQM answered "not recognised" for it. A program
/// that sets a mode and is told nothing about it lays its next screen out
/// against a terminal that is not doing what it asked.
@Suite("ANSI modes")
struct AnsiModeTests {
    private func firstRow(_ input: String, columns: Int = 10) throws -> String {
        var terminal = Terminal(rows: 3, columns: columns)
        terminal.feed(try Golden.decode(input))
        return terminal.grid.rowText(0)
    }

    @Test("IRM starts off, so a write overwrites")
    func insertModeDefaultsOff() throws {
        #expect(try firstRow("abcdef\\e[1;3Hxy") == "abxyef")
    }

    @Test("IRM shifts the rest of the row right instead of overwriting")
    func insertModeShiftsRight() throws {
        #expect(try firstRow("abcdef\\e[1;3H\\e[4hxy") == "abxycdef")
    }

    @Test("RM turns IRM back off")
    func insertModeResets() throws {
        #expect(try firstRow("abcdef\\e[1;3H\\e[4h\\e[4lxy") == "abxyef")
    }

    @Test("cells pushed past the last column are lost, not wrapped")
    func insertModeDropsOverflow() throws {
        // Ten columns: inserting three at column 0 pushes "hij" off the end.
        #expect(try firstRow("abcdefghij\\e[1;1H\\e[4hXYZ") == "XYZabcdefg")
    }

    @Test("IRM makes room for both halves of a wide character")
    func insertModeWide() throws {
        var terminal = Terminal(rows: 2, columns: 8)
        terminal.feed(try Golden.decode("abcdef\\e[1;2H\\e[4h\u{4E16}"))
        // The pair lands at column 1 and "bcdef" moves two columns right.
        #expect(terminal.grid.rowText(0) == "a\u{4E16}bcdef")
    }

    @Test("LNM starts off: a bare LF keeps the column")
    func newLineModeDefaultsOff() throws {
        var terminal = Terminal(rows: 3, columns: 10)
        terminal.feed(try Golden.decode("abc\\nx"))
        #expect(terminal.grid.rowText(1) == "   x")
        #expect(!terminal.isNewLineModeEnabled)
    }

    @Test("LNM makes LF return the carriage too")
    func newLineModeReturnsCarriage() throws {
        var terminal = Terminal(rows: 3, columns: 10)
        terminal.feed(try Golden.decode("\\e[20habc\\nx"))
        #expect(terminal.isNewLineModeEnabled)
        #expect(terminal.grid.rowText(1) == "x")
    }

    @Test("LNM applies to VT and FF as well as LF")
    func newLineModeAppliesToVerticalTabAndFormFeed() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("\\e[20habc\\vx\\fy"))
        #expect(terminal.grid.rowText(1) == "x")
        #expect(terminal.grid.rowText(2) == "y")
    }

    @Test("RM turns LNM back off")
    func newLineModeResets() throws {
        var terminal = Terminal(rows: 3, columns: 10)
        terminal.feed(try Golden.decode("\\e[20h\\e[20l"))
        #expect(!terminal.isNewLineModeEnabled)
    }

    /// `CSI 4 h` and `CSI ? 4 h` are different sequences: the second is
    /// DECSCLM (smooth scroll), which Corta ignores. Before SM/RM existed
    /// they both went nowhere; now only the private form does.
    @Test("the private form of mode 4 is not insert mode")
    func privateFourIsNotInsertMode() throws {
        var terminal = Terminal(rows: 2, columns: 10)
        terminal.feed(try Golden.decode("\\e[?4h"))
        #expect(!terminal.grid.insertMode)
    }

    @Test("an ANSI mode Corta does not implement is ignored cleanly")
    func unknownAnsiModeIsIgnored() throws {
        #expect(try firstRow("\\e[9999h\\e[9999labc") == "abc")
    }
}
