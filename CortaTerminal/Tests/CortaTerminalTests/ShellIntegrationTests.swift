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

    /// Review finding. `CommandRecordStore.record(before:)` must not fall
    /// back to the newest command when the bound is above every prompt — so
    /// scrolling above the first prompt and asking for "the command in view"
    /// answers with the *last* command's output, which is not in view at all.
    @Test("a bound above every prompt has no command, rather than the last one")
    func aBoundBeforeTheFirstPromptFindsNothing() {
        var terminal = Terminal(rows: 6, columns: 20)
        // Two complete commands, each with a prompt, a command mark and a
        // finished mark.
        terminal.feed(Array("\u{1B}]133;A\u{7}$ one\r\n\u{1B}]133;C\u{7}out1\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ two\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;C\u{7}out2\r\n\u{1B}]133;D;0\u{7}".utf8))
        let records = terminal.commandRecords
        #expect(records.lastCompleted != nil, "the fixture must have a command")
        // Row -1 is above everything the fixture wrote.
        #expect(records.record(before: -1) == nil)
    }

    // MARK: - Command records (B07)

    @Test("a completed command gets a stable id and every field")
    func completedCommandRecordIsPopulated() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]7;file:///tmp\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        let records = terminal.commandRecords.records
        #expect(records.count == 1)
        let record = try! #require(records.first)
        #expect(record.id == 0)
        #expect(record.exitStatus == 0)
        #expect(!record.isRunning)
        #expect(!record.didFail)
        #expect(record.workingDirectory == "/tmp")
        #expect(record.outputStartRow != nil)
    }

    @Test("a running command has no exit status and counts as running")
    func runningCommandHasNoExitStatusYet() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ sleep 5\r\n\u{1B}]133;C\u{1B}\\".utf8))
        let record = try! #require(terminal.commandRecords.last)
        #expect(record.isRunning)
        #expect(record.exitStatus == nil)
    }

    @Test("a failed command's record says so")
    func failedCommandRecordDidFail() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;1\u{1B}\\".utf8))
        let record = try! #require(terminal.commandRecords.last)
        #expect(record.didFail)
    }

    /// Each `A` starts a new record, keyed by a ever-increasing id rather
    /// than reused across commands — the identity B07 exists to add.
    @Test("each command gets its own, incrementing id")
    func idsIncrementAcrossCommands() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;0\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;0\u{1B}\\".utf8))
        let records = terminal.commandRecords.records
        #expect(records.map(\.id) == [0, 1])
    }

    /// `lastCompleted` is not `last`: a still-running command must not be
    /// mistaken for "the command that just finished" — the exact confusion
    /// U14's "copy last command's output" existed to avoid.
    @Test("the latest completed command is not the one still running")
    func lastCompletedSkipsARunningCommand() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: nil, at: Date())
        store.finish(exitStatus: 0, endRow: 1, at: Date())
        store.begin(promptRow: 2, workingDirectory: nil, at: Date())
        #expect(store.last?.id == 1)
        #expect(store.lastCompleted?.id == 0)
    }

    @Test("record(before:) finds the command whose prompt is at or before a row")
    func recordBeforeFindsTheRightCommand() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: nil, at: Date())
        store.finish(exitStatus: 0, endRow: 5, at: Date())
        store.begin(promptRow: 10, workingDirectory: nil, at: Date())
        store.finish(exitStatus: 1, endRow: 15, at: Date())
        #expect(store.record(before: 3)?.promptRow == 0)
        #expect(store.record(before: 10)?.promptRow == 10)
        #expect(store.record(before: 20)?.promptRow == 10)
        #expect(store.record(before: -1) == nil)
    }

    /// The bound exists for the same reason scrollback is bounded: a
    /// session left running for days must not grow this without limit.
    @Test("the record store is bounded and drops the oldest first")
    func recordStoreIsBounded() {
        var store = CommandRecordStore()
        for row in 0..<(CommandRecordStore.capacity + 10) {
            store.begin(promptRow: row, workingDirectory: nil, at: Date())
        }
        #expect(store.records.count == CommandRecordStore.capacity)
        #expect(store.records.first?.id == 10)
        #expect(store.records.last?.id == CommandRecordStore.capacity + 9)
    }

    // MARK: - Prompt end position (B08)

    @Test("the prompt end column is where the cursor sits right after B")
    func promptEndColumnIsRecordedAtB() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8))
        let position = try! #require(terminal.promptEndPosition)
        #expect(position.row == 0)
        #expect(position.column == 2)  // "$ " is two columns wide
    }

    @Test("typing after B does not move the recorded prompt end column")
    func typingDoesNotMoveThePromptEndColumn() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8))
        terminal.feed(Array("ls -la".utf8))
        let position = try! #require(terminal.promptEndPosition)
        #expect(position.column == 2)
    }

    @Test("a new prompt clears the previous one's end column until its own B arrives")
    func aNewPromptClearsTheStaleEndColumn() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8))
        terminal.feed(Array("ls\r\n\u{1B}]133;C\u{1B}\\out\r\n\u{1B}]133;D;0\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\".utf8))
        #expect(terminal.promptEndPosition == nil)
        terminal.feed(Array("$ \u{1B}]133;B\u{1B}\\".utf8))
        #expect(terminal.promptEndPosition?.column == 2)
    }

    @Test("B on a different row than A leaves the end column unset")
    func multiLinePromptLeavesEndColumnUnset() {
        var terminal = self.terminal()
        // A two-line prompt: A on row 0, output continues to row 1 before B.
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\prompt line one\r\n$ \u{1B}]133;B\u{1B}\\".utf8))
        #expect(terminal.promptEndPosition == nil)
    }

    @Test("with no shell integration at all, there is no prompt end position")
    func noIntegrationMeansNoPromptEndPosition() {
        let terminal = self.terminal()
        #expect(terminal.promptEndPosition == nil)
    }

    // MARK: - Command record search (B08)

    @Test("records can be filtered by directory, most recent first")
    func recordsFilterByDirectory() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: "/a", at: Date())
        store.finish(exitStatus: 0, endRow: 1, at: Date())
        store.begin(promptRow: 2, workingDirectory: "/b", at: Date())
        store.finish(exitStatus: 0, endRow: 3, at: Date())
        store.begin(promptRow: 4, workingDirectory: "/a", at: Date())
        store.finish(exitStatus: 1, endRow: 5, at: Date())
        let inA = store.records(inDirectory: "/a")
        #expect(inA.map(\.promptRow) == [4, 0])
    }

    @Test("records can be filtered by exit status")
    func recordsFilterByExitStatus() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: nil, at: Date())
        store.finish(exitStatus: 0, endRow: 1, at: Date())
        store.begin(promptRow: 2, workingDirectory: nil, at: Date())
        store.finish(exitStatus: 1, endRow: 3, at: Date())
        #expect(store.records(exitStatus: 1).map(\.promptRow) == [2])
    }

    @Test("records can be filtered by a time range")
    func recordsFilterByTimeRange() {
        var store = CommandRecordStore()
        let base = Date()
        store.begin(promptRow: 0, workingDirectory: nil, at: base.addingTimeInterval(-100))
        store.finish(exitStatus: 0, endRow: 1, at: base.addingTimeInterval(-100))
        store.begin(promptRow: 2, workingDirectory: nil, at: base)
        store.finish(exitStatus: 0, endRow: 3, at: base)
        #expect(store.records(since: base.addingTimeInterval(-1)).map(\.promptRow) == [2])
        #expect(store.records(until: base.addingTimeInterval(-1)).map(\.promptRow) == [0])
    }

    @Test("no filters returns every record, most recent first")
    func noFiltersReturnsEverything() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: nil, at: Date())
        store.begin(promptRow: 1, workingDirectory: nil, at: Date())
        #expect(store.records().map(\.promptRow) == [1, 0])
    }
}
