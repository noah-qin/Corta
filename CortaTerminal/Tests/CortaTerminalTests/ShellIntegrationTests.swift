import Foundation
import Testing

@testable import CortaTerminal

/// M7.2 (OSC 133) and M7.11 (OSC 52) — the two things the child can tell the
/// terminal that it previously had to guess at or could not hear at all.
@Suite struct ShellIntegrationTests {
    private func terminal(rows: Int = 4, columns: Int = 20, scrollback: Int = 100) -> Terminal {
        Terminal(rows: rows, columns: columns, scrollbackLimit: scrollback)
    }

    // MARK: - OSC 133

    @Test("a prompt mark lands on the cursor's row")
    func promptMarksTheRow() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ".utf8))
        #expect(terminal.grid.line(0).mark == .prompt)
        #expect(terminal.grid.line(1).mark == .none)
    }

    @Test("an exit status upgrades the prompt's mark")
    func exitStatusMarksSuccessAndFailure() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        #expect(terminal.isCommandRunning)
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        #expect(!terminal.isCommandRunning)
        #expect(terminal.grid.line(0).mark == .promptSucceeded)

        var failing = self.terminal()
        failing.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;127\u{1B}\\".utf8))
        #expect(failing.grid.line(0).mark == .promptFailed)
    }

    /// The status arrives after the output, which for anything slow has
    /// pushed the prompt row into history. Marking by *absolute* row is what
    /// makes that case work at all.
    @Test("a prompt that scrolled into history is still marked")
    func marksSurviveScrollingIntoHistory() {
        var terminal = self.terminal(rows: 3)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\prompt\r\n\u{1B}]133;C\u{1B}\\".utf8))
        for index in 0..<10 { terminal.feed(Array("line \(index)\r\n".utf8)) }
        terminal.feed(Array("\u{1B}]133;D;1\u{1B}\\".utf8))
        let marked = terminal.grid.promptRows
        #expect(marked.count == 1)
        let row = try! #require(terminal.grid.line(atAbsoluteRow: marked[0]))
        #expect(row.mark == .promptFailed)
    }

    @Test("a finished command is reported once")
    func finishedCommandIsDrained() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;3\u{1B}\\".utf8))
        #expect(terminal.takeFinishedCommand() == 3)
        #expect(terminal.takeFinishedCommand() == nil)
    }

    /// A full-screen application's canvas is not a command history: marks
    /// left on alternate-screen rows would vanish with the screen.
    @Test("marks are ignored on the alternate screen")
    func alternateScreenIsNotMarked() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}[?1049h\u{1B}]133;A\u{1B}\\".utf8))
        #expect(terminal.grid.line(0).mark == .none)
        #expect(terminal.grid.promptRows.isEmpty)
    }

    @Test("a D with no status counts as success")
    func missingStatusIsSuccess() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;D\u{1B}\\".utf8))
        #expect(terminal.grid.line(0).mark == .promptSucceeded)
    }

    // MARK: - OSC 52

    @Test("a base64 payload becomes a pending clipboard copy")
    func clipboardWriteDecodes() {
        var terminal = self.terminal()
        // "hello" — the `c` selection, which is the system clipboard.
        terminal.feed(Array("\u{1B}]52;c;aGVsbG8=\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == "hello")
        #expect(terminal.takeClipboardCopy() == nil)
    }

    /// The read direction is the dangerous one: it hands the local clipboard
    /// to whatever is on the other end of an ssh connection. It answers
    /// nothing, ever (`SECURITY.md` §6).
    @Test("the query form is never answered")
    func clipboardReadIsRefused() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]52;c;?\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == nil)
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test("a malformed payload copies nothing")
    func malformedClipboardPayloadIsIgnored() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]52;c;not base64!!\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == nil)
    }

    /// A stream is not allowed to blank the user's clipboard either.
    @Test("an empty payload copies nothing")
    func emptyClipboardPayloadIsIgnored() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]52;c;\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == nil)
    }

    /// The write form answers nothing either: no reply may carry
    /// stream-supplied text back to the child (`SECURITY.md` §2.1–2.2).
    @Test("a clipboard write produces no reply bytes")
    func clipboardWriteProducesNoOutput() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]52;c;aGVsbG8=\u{1B}\\".utf8))
        #expect(terminal.takeOutput().isEmpty)
    }

    /// Bidi overrides can make pasted text display as something other than
    /// what it is (Trojan Source, `SECURITY.md` §2.5). This payload is
    /// base64 for `abc` + U+202E + `def`: the clipboard must get `abcdef`,
    /// not a string that renders reversed.
    @Test("bidi control characters are stripped from the copy")
    func bidiControlsAreStripped() {
        var terminal = self.terminal()
        let payload = Data("abc\u{202E}def".utf8).base64EncodedString()
        terminal.feed(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == "abcdef")
    }

    /// Zero-width and isolate format characters are stripped the same way;
    /// ZWJ and ZWNJ stay, because emoji sequences and some scripts are
    /// broken without them.
    @Test("invisible format characters are stripped, ZWJ kept")
    func invisibleCharactersAreStrippedZWJKept() {
        var terminal = self.terminal()
        // U+200B ZWSP and U+2066 LRI go; U+200D ZWJ and U+200C ZWNJ stay.
        let payload = Data("a\u{200B}b\u{2066}c\u{200D}d\u{200C}e".utf8).base64EncodedString()
        terminal.feed(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == "abc\u{200D}d\u{200C}e")
    }

    /// A payload of nothing but spoofing characters sanitises to empty,
    /// and empty copies nothing.
    @Test("a payload of only spoofing characters copies nothing")
    func spoofingOnlyPayloadCopiesNothing() {
        var terminal = self.terminal()
        let payload = Data("\u{202E}\u{200B}\u{FEFF}".utf8).base64EncodedString()
        terminal.feed(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == nil)
    }

    /// Data after the `=` padding is not a valid place for more base64;
    /// accepting it would partially apply a malformed payload.
    @Test("data trailing the base64 padding is rejected")
    func dataAfterPaddingIsRejected() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]52;c;aGVsbG8=b3Jn\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == nil)
    }

    /// An OSC 52 longer than the parser's string cap is discarded whole
    /// rather than half-applied, and the stream resynchronises after it.
    @Test("an overlong clipboard payload is discarded, then the parser resyncs")
    func overlongClipboardPayloadIsDiscarded() {
        var terminal = self.terminal()
        var bytes: [UInt8] = Array("\u{1B}]52;c;".utf8)
        bytes.append(contentsOf: repeatElement(UInt8(0x41), count: Parser.maxStringLength + 100))
        bytes.append(contentsOf: Array("\u{1B}\\ok".utf8))
        terminal.feed(bytes)
        #expect(terminal.takeClipboardCopy() == nil)
        #expect(terminal.grid.logicalLine(containing: 0).text.hasPrefix("ok"))
    }
}
