import Testing

@testable import CortaTerminal

/// OSC 4 (set/query the 256-entry indexed palette) and OSC 104 (reset it),
/// B06.
@Suite("Indexed palette (OSC 4/104)")
struct IndexedPaletteTests {
    private func response(to input: String, rows: Int = 24, columns: Int = 80) -> String {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(Array(input.utf8))
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    @Test("OSC 4 sets an index, and the query answers with what was set")
    func setThenQuery() {
        #expect(
            response(to: "\u{1B}]4;5;#ff8000\u{1B}\\\u{1B}]4;5;?\u{1B}\\")
                == "\u{1B}]4;5;rgb:ffff/8080/0000\u{1B}\\")
    }

    @Test("querying an index nobody has set answers with its xterm default")
    func queryUntouchedIndex() {
        // Index 196 is in the 6x6x6 cube: (5, 0, 0) -> (255, 0, 0).
        #expect(response(to: "\u{1B}]4;196;?\u{1B}\\") == "\u{1B}]4;196;rgb:ffff/0000/0000\u{1B}\\")
        // Index 232 is the first greyscale step: level 8.
        #expect(response(to: "\u{1B}]4;232;?\u{1B}\\") == "\u{1B}]4;232;rgb:0808/0808/0808\u{1B}\\")
    }

    @Test("one OSC 4 can carry several index;spec pairs")
    func multiplePairsInOneSequence() {
        #expect(
            response(to: "\u{1B}]4;1;#010101;2;#020202\u{1B}\\\u{1B}]4;1;?\u{1B}\\\u{1B}]4;2;?\u{1B}\\")
                == "\u{1B}]4;1;rgb:0101/0101/0101\u{1B}\\\u{1B}]4;2;rgb:0202/0202/0202\u{1B}\\")
    }

    @Test("OSC 104 with one index resets only that index")
    func resetOneIndex() {
        #expect(
            response(to: "\u{1B}]4;1;#ffffff\u{1B}\\\u{1B}]104;1\u{1B}\\\u{1B}]4;1;?\u{1B}\\")
                == "\u{1B}]4;1;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("OSC 104 with several indices resets each of them")
    func resetSeveralIndices() {
        #expect(
            response(
                to: "\u{1B}]4;1;#ffffff;2;#ffffff\u{1B}\\\u{1B}]104;1;2\u{1B}\\"
                    + "\u{1B}]4;1;?\u{1B}\\\u{1B}]4;2;?\u{1B}\\")
                == "\u{1B}]4;1;rgb:0000/0000/0000\u{1B}\\\u{1B}]4;2;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("OSC 104 with no arguments and a semicolon resets every index")
    func resetAllWithTrailingSemicolon() {
        #expect(
            response(to: "\u{1B}]4;1;#ffffff\u{1B}\\\u{1B}]104;\u{1B}\\\u{1B}]4;1;?\u{1B}\\")
                == "\u{1B}]4;1;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("a bare OSC 104 with no semicolon at all also resets every index")
    func resetAllBareForm() {
        // xterm itself sends exactly this form; oscDispatch has no
        // separator to key off at all here.
        #expect(
            response(to: "\u{1B}]4;1;#ffffff\u{1B}\\\u{1B}]104\u{1B}\\\u{1B}]4;1;?\u{1B}\\")
                == "\u{1B}]4;1;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("an index above 255 is ignored rather than corrupting the palette")
    func outOfRangeIndexIsIgnored() {
        // 256 doesn't fit in a UInt8; the whole pair must be dropped, not
        // wrap around to some in-range index.
        #expect(response(to: "\u{1B}]4;256;#ffffff\u{1B}\\\u{1B}]4;1;?\u{1B}\\")
            == "\u{1B}]4;1;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("a malformed spec does not stop later pairs in the same sequence")
    func malformedPairIsSkipped() {
        #expect(
            response(to: "\u{1B}]4;1;notacolor;2;#020202\u{1B}\\\u{1B}]4;2;?\u{1B}\\")
                == "\u{1B}]4;2;rgb:0202/0202/0202\u{1B}\\")
    }

    @Test("a malformed or out-of-range index does not stop later pairs either")
    func malformedIndexIsSkipped() {
        #expect(
            response(to: "\u{1B}]4;256;#ffffff;2;#020202\u{1B}\\\u{1B}]4;2;?\u{1B}\\")
                == "\u{1B}]4;2;rgb:0202/0202/0202\u{1B}\\")
        #expect(
            response(to: "\u{1B}]4;notanumber;#ffffff;2;#020202\u{1B}\\\u{1B}]4;2;?\u{1B}\\")
                == "\u{1B}]4;2;rgb:0202/0202/0202\u{1B}\\")
    }

    @Test("RIS keeps the app-seeded palette defaults but clears overrides")
    func risKeepsDefaultsClearsOverrides() {
        var terminal = Terminal()
        var seededDefaults = IndexedPalette.xtermDefaults()
        // A non-black value at index 1: the xterm defaults ship it black, so
        // asserting black after reset would pass even if the whole palette
        // (not just the override) were discarded and rebuilt from scratch.
        seededDefaults[1] = (200, 100, 50)
        var palette = IndexedPalette(defaults: seededDefaults)
        palette.setOverride(1, to: (10, 20, 30))
        terminal.indexedPalette = palette
        terminal.reset()
        #expect(terminal.indexedPalette.overrides.isEmpty)
        #expect(terminal.indexedPalette.color(at: 1) as (UInt8, UInt8, UInt8) == (200, 100, 50))
    }

    @Test("no OSC 4 or 104 produces unsolicited output")
    func noOutputWithoutAQuery() {
        var terminal = Terminal()
        terminal.feed(Array("\u{1B}]4;1;#ffffff\u{1B}\\\u{1B}]104\u{1B}\\".utf8))
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test("updateDefaults reseeds untouched indices without discarding overrides")
    func updateDefaultsPreservesOverrides() {
        var palette = IndexedPalette()
        palette.setOverride(1, to: (10, 20, 30))
        var newDefaults = IndexedPalette.xtermDefaults()
        // Index 2 is left untouched by the override above, so changing its
        // default here is what actually exercises the reseed — changing
        // index 1's instead would pass even if `updateDefaults` were a
        // no-op, since the override already shadows it.
        newDefaults[2] = (99, 98, 97)
        palette.updateDefaults(to: newDefaults)
        // The override survives the reseed...
        #expect(palette.color(at: 1) as (UInt8, UInt8, UInt8) == (10, 20, 30))
        // ...but an untouched index picks up the new default.
        #expect(palette.color(at: 2) as (UInt8, UInt8, UInt8) == (99, 98, 97))
    }

    @Test("the core-level palette getter/setter round-trips overrides")
    func terminalIndexedPaletteProperty() {
        var terminal = Terminal()
        var palette = terminal.indexedPalette
        #expect(palette.color(at: 9) == (0, 0, 0))
        palette.setOverride(9, to: (10, 20, 30))
        terminal.indexedPalette = palette
        #expect(terminal.indexedPalette.color(at: 9) as (UInt8, UInt8, UInt8) == (10, 20, 30))
    }
}
