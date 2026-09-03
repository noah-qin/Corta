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
}
