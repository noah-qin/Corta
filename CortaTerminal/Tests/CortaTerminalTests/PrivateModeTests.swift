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

    @Test("RIS clears ?2026 — a terminal reset ends any synchronized-output episode")
    func risClearsSynchronizedOutput() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2026h"))
        #expect(terminal.isSynchronizedOutputEnabled)
        terminal.feed(try Golden.decode("\\ec"))
        #expect(!terminal.isSynchronizedOutputEnabled)
    }

    @Test("endSynchronizedOutput force-ends an episode without the child's DECRST")
    func endSynchronizedOutputForceClears() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2026h"))
        #expect(terminal.isSynchronizedOutputEnabled)
        terminal.endSynchronizedOutput()
        #expect(!terminal.isSynchronizedOutputEnabled)
    }

    @Test("a DECRST+BSU pair in one batch still counts a new episode")
    func decrstBsuInOneBatchStartsANewEpisode() throws {
        var terminal = Terminal()
        terminal.feed(try Golden.decode("\\e[?2026h"))
        #expect(terminal.synchronizedOutputEpisode == 1)
        // Both transitions in one feed — a compliant renderer's normal frame
        // loop. A before/after bool compare reads on → on and misses the new
        // episode, leaving it under the previous episode's recovery timer.
        terminal.feed(try Golden.decode("\\e[?2026l\\e[?2026h"))
        #expect(terminal.isSynchronizedOutputEnabled)
        #expect(terminal.synchronizedOutputEpisode == 2)
        // A repeated BSU inside an episode is not a new edge.
        terminal.feed(try Golden.decode("\\e[?2026h"))
        #expect(terminal.synchronizedOutputEpisode == 2)
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

/// U04 — DECKPAM / DECKPNM (`ESC =` / `ESC >`). The app encodes keys, so the
/// mode is state the core tracks and answers for; `xterm-256color`'s `smkx`
/// sends `\E[?1h\E=`, which is why the two arrive together.
@Suite struct ApplicationKeypadModeTests {
    @Test("the keypad starts in numeric mode")
    func defaultsToNumeric() {
        let terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 0)
        #expect(!terminal.applicationKeypadEnabled)
    }

    @Test("ESC = enables it and ESC > disables it")
    func decpamAndDecpnm() {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 0)
        terminal.feed(Array("\u{1B}=".utf8))
        #expect(terminal.applicationKeypadEnabled)
        terminal.feed(Array("\u{1B}>".utf8))
        #expect(!terminal.applicationKeypadEnabled)
    }

    /// What terminfo actually sends: `smkx` is `\E[?1h\E=` and `rmkx` is
    /// `\E[?1l\E>`, so the two modes move together and neither swallows the
    /// other's sequence.
    @Test("smkx and rmkx set both keyboard modes")
    func terminfoPair() {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 0)
        terminal.feed(Array("\u{1B}[?1h\u{1B}=".utf8))
        #expect(terminal.applicationCursorKeysEnabled)
        #expect(terminal.applicationKeypadEnabled)
        terminal.feed(Array("\u{1B}[?1l\u{1B}>".utf8))
        #expect(!terminal.applicationCursorKeysEnabled)
        #expect(!terminal.applicationKeypadEnabled)
    }

    /// RIS puts it back, like every other mode.
    @Test("RIS resets it")
    func resetClearsIt() {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 0)
        terminal.feed(Array("\u{1B}=".utf8))
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(!terminal.applicationKeypadEnabled)
    }
}
