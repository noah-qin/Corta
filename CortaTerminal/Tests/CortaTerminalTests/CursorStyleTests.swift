import Testing

@testable import CortaTerminal

/// M2.5 — DECSCUSR (`CSI Ps SP q`, xterm ctlseqs), driven through a
/// terminal because the parameter mapping is the performer's job.
@Suite("Cursor style")
struct CursorStyleTests {
    private func fed(_ input: String) -> Terminal {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(input.utf8)
        return terminal
    }

    @Test("the default is a blinking block")
    func defaultIsBlinkingBlock() {
        #expect(fed("").grid.cursorStyle == .blinkingBlock)
    }

    /// xterm ctlseqs: 0 and 1 blinking block, 2 steady block, 3 blinking
    /// underline, 4 steady underline, 5 blinking bar, 6 steady bar.
    @Test("parameters map to the styles xterm documents", arguments: [
        ("\u{1B}[0 q", CursorStyle.blinkingBlock),
        ("\u{1B}[1 q", .blinkingBlock),
        ("\u{1B}[2 q", .block),
        ("\u{1B}[3 q", .blinkingUnderline),
        ("\u{1B}[4 q", .underline),
        ("\u{1B}[5 q", .blinkingBar),
        ("\u{1B}[6 q", .bar),
    ])
    func parameterMapsToStyle(_ input: String, _ style: CursorStyle) {
        #expect(fed(input).grid.cursorStyle == style)
    }

    @Test("an unknown parameter is ignored")
    func unknownParameterIsIgnored() {
        #expect(fed("\u{1B}[2 q\u{1B}[99 q").grid.cursorStyle == .block)
    }

    /// The style is global to the terminal: set on the alternate screen, it
    /// is still the style after switching back (xterm ctlseqs; DECSCUSR is
    /// not part of the ?1049 save/restore).
    @Test("the style survives an alternate-screen round trip")
    func styleSurvivesAlternateScreen() {
        #expect(fed("\u{1B}[?1049h\u{1B}[5 q\u{1B}[?1049l").grid.cursorStyle == .blinkingBar)
    }
}
