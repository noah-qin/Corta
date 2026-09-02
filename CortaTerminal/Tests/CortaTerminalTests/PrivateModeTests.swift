import Testing

@testable import CortaTerminal

/// M2.6/M2.7, core side — the `?2004` bracketed-paste and `?1006` SGR mouse
/// flags, set by DECSET/DECRST and read by the app layer later.
@Suite("Private modes")
struct PrivateModeTests {
    @Test("both flags start off")
    func defaults() {
        let terminal = Terminal()
        #expect(!terminal.isBracketedPasteEnabled)
        #expect(!terminal.isSgrMouseEncodingEnabled)
    }

    @Test("DECSET enables and DECRST disables each flag")
    func toggle() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2004h"))
        #expect(terminal.isBracketedPasteEnabled)
        #expect(!terminal.isSgrMouseEncodingEnabled)

        terminal.feed(try Golden.decode("\\e[?1006h"))
        #expect(terminal.isSgrMouseEncodingEnabled)

        terminal.feed(try Golden.decode("\\e[?2004l\\e[?1006l"))
        #expect(!terminal.isBracketedPasteEnabled)
        #expect(!terminal.isSgrMouseEncodingEnabled)
    }

    @Test("several modes in one sequence all apply")
    func severalInOneSequence() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2004;1006h"))
        #expect(terminal.isBracketedPasteEnabled)
        #expect(terminal.isSgrMouseEncodingEnabled)
    }

    /// The plain form `CSI 2004 h` (no `?`) is a different sequence and must
    /// not touch the private-mode flags.
    @Test("a missing private marker is a different sequence")
    func plainSetModeIsNotPrivate() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[2004h\\e[1006h"))
        #expect(!terminal.isBracketedPasteEnabled)
        #expect(!terminal.isSgrMouseEncodingEnabled)
    }

    /// Modes this terminal does not implement — `?7` auto-wrap, `?25` cursor
    /// visibility — must not disturb the screen or produce output. (`?1049`
    /// used to be the example here; it is implemented now and covered by the
    /// alternate-screen tests.)
    @Test("unimplemented modes are ignored cleanly")
    func unknownModesAreIgnored() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("hi\\e[?7h\\e[?25lb"))
        #expect(terminal.grid[0, 0].scalar == 0x68)
        #expect(terminal.grid[0, 1].scalar == 0x69)
        #expect(terminal.grid[0, 2].scalar == 0x62)
        #expect(!terminal.hasPendingOutput)
    }

    @Test("mode changes produce no output")
    func noOutput() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2004h\\e[?1006h\\e[?2004l"))
        #expect(terminal.takeOutput().isEmpty)
    }

    // MARK: - M4.3 synchronized output

    @Test("?2026 starts off, DECSET turns it on, DECRST turns it off")
    func synchronizedOutputToggle() throws {
        var terminal = Terminal()
        #expect(!terminal.isSynchronizedOutputEnabled)
        terminal.feed(try Golden.decode("\\e[?2026h"))
        #expect(terminal.isSynchronizedOutputEnabled)
        terminal.feed(try Golden.decode("\\e[?2026l"))
        #expect(!terminal.isSynchronizedOutputEnabled)
    }
}

/// M4.8, core side — BEL sets a flag the app reads and clears; the core
/// decides nothing about audible, visual or muted.
@Suite("Bell")
struct BellTests {
    @Test("BEL sets the flag; takeBell consumes it exactly once")
    func bellIsConsumedOnce() {
        var terminal = Terminal()
        let none = terminal.takeBell()
        #expect(!none)
        terminal.feed([0x07])
        let first = terminal.takeBell()
        let second = terminal.takeBell()
        #expect(first)
        #expect(!second)
    }

    @Test("two bells before a read still read as pending once")
    func repeatedBellsCollapse() {
        var terminal = Terminal()
        terminal.feed([0x07, 0x07])
        let first = terminal.takeBell()
        let second = terminal.takeBell()
        #expect(first)
        #expect(!second)
    }

    @Test("BEL produces no query output")
    func bellProducesNoOutput() {
        var terminal = Terminal()
        terminal.feed([0x07])
        #expect(terminal.takeOutput().isEmpty)
    }
}
