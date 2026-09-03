import Testing

@testable import CortaTerminal

/// M6.5 and M6.6 — the query class the esctest failures were dominated by.
/// A probe that goes unanswered times out by design, so what these assert is
/// not just the shape of each answer but that an answer exists at all.
@Suite("Mode and colour queries")
struct ModeQueryTests {
    private func response(to input: String, rows: Int = 24, columns: Int = 80) -> String {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(Array(input.utf8))
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    // MARK: - DECRQM (M6.5)

    @Test("DECRQM reports a private mode the child has just set")
    func decrqmReportsASetPrivateMode() {
        // Bracketed paste on, then asked about: `CSI ? 2004 ; 1 $ y`.
        #expect(response(to: "\u{1B}[?2004h\u{1B}[?2004$p") == "\u{1B}[?2004;1$y")
    }

    @Test("DECRQM reports a private mode the child has reset")
    func decrqmReportsAResetPrivateMode() {
        #expect(response(to: "\u{1B}[?2004h\u{1B}[?2004l\u{1B}[?2004$p") == "\u{1B}[?2004;2$y")
    }

    @Test("a mode never touched reports as reset, not as unknown")
    func decrqmReportsAnUntouchedKnownModeAsReset() {
        #expect(response(to: "\u{1B}[?2026$p") == "\u{1B}[?2026;2$y")
    }

    @Test("the alternate screen answers from the grid, not from a flag")
    func decrqmReportsTheAlternateScreen() {
        #expect(response(to: "\u{1B}[?1049h\u{1B}[?1049$p") == "\u{1B}[?1049;1$y")
        #expect(response(to: "\u{1B}[?1049$p") == "\u{1B}[?1049;2$y")
    }

    @Test("autowrap and cursor visibility report as permanently set")
    func decrqmReportsPermanentModes() {
        #expect(response(to: "\u{1B}[?7$p") == "\u{1B}[?7;3$y")
        #expect(response(to: "\u{1B}[?25$p") == "\u{1B}[?25;3$y")
    }

    @Test("an unimplemented mode is answered 0 rather than left to time out")
    func decrqmAnswersUnknownModesWithZero() {
        #expect(response(to: "\u{1B}[?9999$p") == "\u{1B}[?9999;0$y")
    }

    @Test("the ANSI form has no ? in either the request or the reply")
    func decrqmAnsiForm() {
        #expect(response(to: "\u{1B}[1$p") == "\u{1B}[1;4$y")
        #expect(response(to: "\u{1B}[20$p") == "\u{1B}[20;0$y")
    }

    /// The ECMA-48 modes describing hardware an emulator has no analogue of
    /// answer 4 — permanently reset — which is a stronger answer than 0: a
    /// program learns not to ask again.
    @Test("modes Corta will never implement answer permanently reset")
    func decrqmPermanentlyResetAnsiModes() {
        for mode in [1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19] {
            #expect(response(to: "\u{1B}[\(mode)$p") == "\u{1B}[\(mode);4$y")
        }
    }

    /// A program that announced VT200 with DECSCL has asked to be talked to
    /// as an older terminal; DECRQM arrived at VT300.
    @Test("DECRQM goes unanswered below the conformance level that defines it")
    func decrqmRespectsTheConformanceLevel() {
        #expect(response(to: "\u{1B}[62;0\"p\u{1B}[?2004$p").isEmpty)
        #expect(response(to: "\u{1B}[63;0\"p\u{1B}[?2004$p") == "\u{1B}[?2004;2$y")
        // Back up to the default level and it answers again.
        #expect(response(to: "\u{1B}[62;0\"p\u{1B}[65;0\"p\u{1B}[?2004$p") == "\u{1B}[?2004;2$y")
    }

    @Test("DECRQM does not change the mode it asks about")
    func decrqmIsAQuestionNotACommand() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("\u{1B}[?2004$p".utf8))
        #expect(!terminal.isBracketedPasteEnabled)
    }

    // MARK: - XTVERSION (M6.5)

    @Test("XTVERSION answers with a DCS-wrapped name and version")
    func xtversionAnswers() {
        #expect(response(to: "\u{1B}[>0q") == "\u{1B}P>|Corta(0.1.0)\u{1B}\\")
        // `CSI > q` with no parameter is the same request.
        #expect(response(to: "\u{1B}[>q") == "\u{1B}P>|Corta(0.1.0)\u{1B}\\")
    }

    @Test("a different Ps is a different sequence and goes unanswered")
    func xtversionIgnoresOtherParameters() {
        #expect(response(to: "\u{1B}[>1q").isEmpty)
    }

    // MARK: - Focus reporting (M6.7)

    @Test("?1004 tracks like the other private modes")
    func focusReportingMode() {
        var terminal = Terminal(rows: 5, columns: 10)
        #expect(!terminal.isFocusReportingEnabled)
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        #expect(terminal.isFocusReportingEnabled)
        terminal.feed(Array("\u{1B}[?1004l".utf8))
        #expect(!terminal.isFocusReportingEnabled)
    }

    @Test("DECRQM can be asked about focus reporting")
    func focusReportingIsQueryable() {
        #expect(response(to: "\u{1B}[?1004h\u{1B}[?1004$p") == "\u{1B}[?1004;1$y")
    }

    // MARK: - Dynamic colours (M6.6)

    @Test("OSC 11 ? reports the background as 16-bit rgb")
    func oscBackgroundQuery() {
        // The default background is (35, 40, 51) — 0x23, 0x28, 0x33.
        #expect(
            response(to: "\u{1B}]11;?\u{1B}\\") == "\u{1B}]11;rgb:2323/2828/3333\u{1B}\\")
    }

    @Test("the set form is reflected by the next query")
    func oscColorRoundTrip() {
        #expect(
            response(to: "\u{1B}]10;#ff8000\u{1B}\\\u{1B}]10;?\u{1B}\\")
                == "\u{1B}]10;rgb:ffff/8080/0000\u{1B}\\")
        #expect(
            response(to: "\u{1B}]12;rgb:1/2/3\u{1B}\\\u{1B}]12;?\u{1B}\\")
                == "\u{1B}]12;rgb:1111/2222/3333\u{1B}\\")
    }

    @Test("a 16-bit specification scales down to 8 bits")
    func oscColorScalesWideChannels() {
        #expect(
            response(to: "\u{1B}]11;rgb:ffff/0000/8080\u{1B}\\\u{1B}]11;?\u{1B}\\")
                == "\u{1B}]11;rgb:ffff/0000/8080\u{1B}\\")
    }

    @Test("a malformed specification leaves the colour alone")
    func oscColorRejectsGarbage() {
        #expect(
            response(to: "\u{1B}]11;not-a-colour\u{1B}\\\u{1B}]11;?\u{1B}\\")
                == "\u{1B}]11;rgb:2323/2828/3333\u{1B}\\")
        #expect(
            response(to: "\u{1B}]11;rgb:1/2\u{1B}\\\u{1B}]11;?\u{1B}\\")
                == "\u{1B}]11;rgb:2323/2828/3333\u{1B}\\")
    }

    /// The rule the whole query class is built to keep: an answer is
    /// formatted from numeric state, never assembled out of the request.
    @Test("a colour query never echoes bytes from the request")
    func oscColorNeverEchoesTheRequest() {
        let reply = response(to: "\u{1B}]11;?; rm -rf /\u{1B}\\")
        #expect(!reply.contains("rm -rf"))
    }
}
