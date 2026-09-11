import Testing

@testable import CortaTerminal

/// OSC 5 (query/set the five special colours) and OSC 105 (reset), B06.
/// Mirrors `IndexedPaletteTests`' shape for OSC 4/104, over
/// `SpecialColors`' five fixed slots instead of a 256-entry palette.
@Suite("Special colours (OSC 5/105)")
struct SpecialColorsTests {
    private func response(to input: String, rows: Int = 24, columns: Int = 80) -> String {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(Array(input.utf8))
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    @Test("OSC 5 sets a slot, and the query answers with what was set")
    func setThenQuery() {
        #expect(
            response(to: "\u{1B}]5;0;#ff8000\u{1B}\\\u{1B}]5;0;?\u{1B}\\")
                == "\u{1B}]5;0;rgb:ffff/8080/0000\u{1B}\\")
    }

    @Test("querying a slot nobody has set answers black, not silence")
    func queryUnsetSlotAnswersBlack() {
        #expect(response(to: "\u{1B}]5;2;?\u{1B}\\") == "\u{1B}]5;2;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("one OSC 5 can carry several slot;spec pairs")
    func multiplePairsInOneSequence() {
        #expect(
            response(to: "\u{1B}]5;0;#010101;1;#020202\u{1B}\\\u{1B}]5;0;?\u{1B}\\\u{1B}]5;1;?\u{1B}\\")
                == "\u{1B}]5;0;rgb:0101/0101/0101\u{1B}\\\u{1B}]5;1;rgb:0202/0202/0202\u{1B}\\")
    }

    @Test("OSC 105 with one slot resets only that slot")
    func resetOneSlot() {
        #expect(
            response(to: "\u{1B}]5;3;#ffffff\u{1B}\\\u{1B}]105;3\u{1B}\\\u{1B}]5;3;?\u{1B}\\")
                == "\u{1B}]5;3;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("OSC 105 with several slots resets each of them")
    func resetSeveralSlots() {
        #expect(
            response(
                to: "\u{1B}]5;0;#ffffff;1;#ffffff\u{1B}\\\u{1B}]105;0;1\u{1B}\\"
                    + "\u{1B}]5;0;?\u{1B}\\\u{1B}]5;1;?\u{1B}\\")
                == "\u{1B}]5;0;rgb:0000/0000/0000\u{1B}\\\u{1B}]5;1;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("OSC 105 with no arguments and a semicolon resets every slot")
    func resetAllWithTrailingSemicolon() {
        #expect(
            response(to: "\u{1B}]5;0;#ffffff\u{1B}\\\u{1B}]105;\u{1B}\\\u{1B}]5;0;?\u{1B}\\")
                == "\u{1B}]5;0;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("a bare OSC 105 with no semicolon at all also resets every slot")
    func resetAllBareForm() {
        #expect(
            response(to: "\u{1B}]5;0;#ffffff\u{1B}\\\u{1B}]105\u{1B}\\\u{1B}]5;0;?\u{1B}\\")
                == "\u{1B}]5;0;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("a slot above 4 is ignored rather than trapping")
    func outOfRangeSlotIsIgnored() {
        #expect(response(to: "\u{1B}]5;5;#ffffff\u{1B}\\\u{1B}]5;0;?\u{1B}\\")
            == "\u{1B}]5;0;rgb:0000/0000/0000\u{1B}\\")
    }

    @Test("a malformed spec or slot does not stop later pairs in the same sequence")
    func malformedPairIsSkipped() {
        #expect(
            response(to: "\u{1B}]5;0;notacolor;1;#020202\u{1B}\\\u{1B}]5;1;?\u{1B}\\")
                == "\u{1B}]5;1;rgb:0202/0202/0202\u{1B}\\")
        #expect(
            response(to: "\u{1B}]5;9;#ffffff;1;#020202\u{1B}\\\u{1B}]5;1;?\u{1B}\\")
                == "\u{1B}]5;1;rgb:0202/0202/0202\u{1B}\\")
    }

    @Test("no OSC 5 or 105 produces unsolicited output")
    func noOutputWithoutAQuery() {
        var terminal = Terminal()
        terminal.feed(Array("\u{1B}]5;0;#ffffff\u{1B}\\\u{1B}]105\u{1B}\\".utf8))
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test("RIS resets every special colour")
    func risResetsThem() {
        var terminal = Terminal()
        terminal.feed(Array("\u{1B}]5;0;#ffffff\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(terminal.specialColors.overrides.isEmpty)
    }

    @Test("the core-level getter/setter round-trips overrides")
    func terminalSpecialColorsProperty() {
        var terminal = Terminal()
        var colors = terminal.specialColors
        #expect(colors.color(at: .bold) == nil)
        colors.setOverride(.bold, to: (10, 20, 30))
        terminal.specialColors = colors
        let stored = terminal.specialColors.color(at: .bold)
        #expect(stored?.red == 10 && stored?.green == 20 && stored?.blue == 30)
    }

    @Test("all five slots round-trip through the wire form")
    func allFiveSlotsRoundTrip() {
        for slot: UInt8 in 0...4 {
            #expect(
                response(to: "\u{1B}]5;\(slot);#123456\u{1B}\\\u{1B}]5;\(slot);?\u{1B}\\")
                    == "\u{1B}]5;\(slot);rgb:1212/3434/5656\u{1B}\\")
        }
    }
}
