import Testing

@testable import CortaTerminal

/// M1.10–M1.12 — printable text, the C0 controls, cursor movement and erase,
/// asserted cell by cell. The golden files cover the same ground as whole
/// screens; these assert the details a dump comparison hides.
@Suite("Performer")
struct PerformerTests {
    private func terminal(
        _ source: String,
        rows: Int = 4,
        columns: Int = 10
    ) throws -> Terminal {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(try Golden.decode(source))
        return terminal
    }

    // MARK: - M1.10, text and C0

    @Test("printable text lands in consecutive cells")
    func printableText() throws {
        let terminal = try self.terminal("hi")
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 2))
        #expect(terminal.grid[0, 0].scalar == 0x68)
        #expect(terminal.grid[0, 1].scalar == 0x69)
        #expect(terminal.grid[0, 2] == .blank)
    }

    /// LF moves down without changing the column — the reason a program that
    /// prints "\n" without "\r" produces a staircase.
    @Test("line feed keeps the column, carriage return resets it")
    func lineFeedAndCarriageReturn() throws {
        var terminal = try self.terminal("abc\\n")
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 3))

        terminal.feed(try Golden.decode("\\r"))
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 0))
    }

    @Test("tab advances to the next eighth column")
    func tab() throws {
        let terminal = try self.terminal("a\\tb", columns: 20)
        #expect(terminal.grid[0, 0].scalar == 0x61)
        #expect(terminal.grid[0, 8].scalar == 0x62)
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 9))
    }

    @Test("backspace moves left without erasing")
    func backspace() throws {
        let terminal = try self.terminal("ab\\b")
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 1))
        #expect(terminal.grid[0, 1].scalar == 0x62)
    }

    /// A UTF-8 character split across two chunks is one character, and the
    /// cursor advances once.
    @Test("a character split across two feeds is one cell")
    func splitCharacter() throws {
        var terminal = Terminal(rows: 2, columns: 10)
        terminal.feed([0xE4, 0xBD])
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 0))
        terminal.feed([0xA0])
        #expect(terminal.grid[0, 0].scalar == 0x4F60)
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 1))
    }

    // MARK: - M1.11, cursor

    @Test("CUP is one-based and clamped to the screen")
    func cursorPosition() throws {
        #expect(try terminal("\\e[3;5H").grid.cursor == Cursor(row: 2, column: 4))
        // Both parameters default to 1: home.
        #expect(try terminal("\\e[3;5H\\e[H").grid.cursor == Cursor(row: 0, column: 0))
        #expect(try terminal("\\e[99;99H").grid.cursor == Cursor(row: 3, column: 9))
        // HVP has the same meaning as CUP.
        #expect(try terminal("\\e[2;2f").grid.cursor == Cursor(row: 1, column: 1))
    }

    @Test("the relative movements default to one and stop at the edges")
    func relativeMovement() throws {
        #expect(try terminal("\\e[3;5H\\e[A").grid.cursor == Cursor(row: 1, column: 4))
        #expect(try terminal("\\e[3;5H\\e[2B").grid.cursor == Cursor(row: 3, column: 4))
        #expect(try terminal("\\e[3;5H\\e[3C").grid.cursor == Cursor(row: 2, column: 7))
        #expect(try terminal("\\e[3;5H\\e[2D").grid.cursor == Cursor(row: 2, column: 2))

        // Clamped, not wrapped, and a hostile parameter is still clamped.
        #expect(try terminal("\\e[3;5H\\e[99A").grid.cursor == Cursor(row: 0, column: 4))
        #expect(try terminal("\\e[3;5H\\e[99999999D").grid.cursor == Cursor(row: 2, column: 0))
    }

    /// `CSI ? 25 h` is not `CSI 25 h`. A sequence with a private marker or an
    /// intermediate is a different sequence, and an unimplemented one is
    /// ignored rather than guessed at.
    @Test("a private marker or intermediate is not treated as the plain form")
    func privateSequencesAreIgnored() throws {
        #expect(try terminal("\\e[3;5H\\e[?2A").grid.cursor == Cursor(row: 2, column: 4))
        #expect(try terminal("\\e[3;5H\\e[2 A").grid.cursor == Cursor(row: 2, column: 4))
    }

    // MARK: - M1.12, erase

    @Test("erase in line respects the mode and leaves the cursor")
    func eraseInLine() throws {
        let toEnd = try terminal("abcdef\\e[1;3H\\e[K")
        #expect(toEnd.grid.cursor == Cursor(row: 0, column: 2))
        #expect(toEnd.grid[0, 1].scalar == 0x62)
        #expect(toEnd.grid[0, 2] == .blank)

        let toStart = try terminal("abcdef\\e[1;3H\\e[1K")
        #expect(toStart.grid[0, 2] == .blank)
        #expect(toStart.grid[0, 3].scalar == 0x64)

        let whole = try terminal("abcdef\\e[1;3H\\e[2K")
        #expect(whole.grid.line(0).isEmpty)
        #expect(whole.grid.cursor == Cursor(row: 0, column: 2))
    }

    @Test("erase in display respects the mode")
    func eraseInDisplay() throws {
        let source = "aaa\\r\\nbbb\\r\\nccc\\r\\nddd"

        let toEnd = try terminal(source + "\\e[2;2H\\e[J")
        #expect(toEnd.grid[1, 0].scalar == 0x62)
        #expect(toEnd.grid[1, 1] == .blank)
        #expect(toEnd.grid.line(2).isEmpty)

        let toStart = try terminal(source + "\\e[2;2H\\e[1J")
        #expect(toStart.grid.line(0).isEmpty)
        #expect(toStart.grid[1, 1] == .blank)
        #expect(toStart.grid[1, 2].scalar == 0x62)
        #expect(toStart.grid[2, 0].scalar == 0x63)

        let whole = try terminal(source + "\\e[2;2H\\e[2J")
        for row in 0..<4 { #expect(whole.grid.line(row).isEmpty) }
        #expect(whole.grid.cursor == Cursor(row: 1, column: 1))
    }

    /// An unimplemented sequence must not corrupt the screen or the stream.
    @Test("an unknown sequence is skipped and the text after it prints")
    func unknownSequencesAreSkipped() throws {
        let terminal = try self.terminal("a\\e[12345;6789zb")
        #expect(terminal.grid[0, 0].scalar == 0x61)
        #expect(terminal.grid[0, 1].scalar == 0x62)
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 2))
    }
}
