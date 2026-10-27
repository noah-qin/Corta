// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CortaTerminal

extension ShellIntegrationTests {
    /// A command that clears the screen while it runs is not a prompt
    /// repainted: its prompt stays where it was.
    @Test("an erase while a command runs leaves the prompt alone")
    func anEraseDuringACommandDoesNotMoveThePrompt() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ true\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}$ top\r\n\u{1B}]133;C\u{7}\u{1B}[H\u{1B}[2J".utf8))
        #expect(terminal.commandRecords.last?.promptRow == 1)
        #expect(terminal.grid.line(0).mark == .none)
    }

    /// Erasing part of the screen keeps the rows it did not touch.
    @Test("an erase below the cursor keeps the prompt's mark")
    func eraseBelowKeepsTheCursorRowsMark() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}[J\u{1B}]133;C\u{1B}\\\u{1B}]133;D;1\u{1B}\\".utf8))
        #expect(terminal.grid.line(0).mark == .promptFailed)
    }

    /// fish 4 marks its own prompts, so with Corta's fish hook as well every
    /// prompt carried two of each mark — the order below is fish 4.9's,
    /// recorded. The hook's `D`, straight after fish's `A`, closed a phantom
    /// command with the last one's status and coloured the waiting prompt.
    @Test("a hook doubled with fish 4's own marks records each command once")
    func doubledFishMarksRecordOneCommand() {
        var terminal = self.terminal(rows: 8)
        let fishA = "\u{1B}]133;A;click_events=1\u{7}"
        func prompt(status: Int) -> String {
            fishA + "\u{1B}]133;D;\(status)\u{7}\u{1B}]133;A\u{7}> \u{1B}]133;B\u{7}\u{1B}]133;B\u{7}"
        }
        func run(_ command: String, status: Int) -> String {
            command + "\r\n\u{1B}]133;C;cmdline_url=\(command)\u{7}\u{1B}]133;C\u{7}"
                + "out\r\n\u{1B}]133;D;\(status)\u{7}"
        }
        terminal.feed(Array((prompt(status: 0) + run("false", status: 1)).utf8))
        terminal.feed(Array((prompt(status: 1) + run("true", status: 0)).utf8))
        terminal.feed(Array(prompt(status: 0).utf8))

        // Before the first `C` the shell may be one that never sends it, so
        // the session's first prompt still yields one empty record; every
        // prompt after it, none.
        let records = terminal.commandRecords.records
        #expect(records.map(\.exitStatus) == [0, 1, 0, nil])
        #expect(records.map(\.promptRow) == [0, 0, 2, 4])
        #expect(records.first?.outputStartRow == nil)
        #expect(terminal.commandRecords.lastCompleted?.promptRow == 2)
        #expect(terminal.grid.line(0).mark == .promptFailed)
        #expect(terminal.grid.line(2).mark == .promptSucceeded)
        // The waiting prompt: nothing has run there yet.
        #expect(terminal.grid.line(4).mark == .prompt)
        #expect(!terminal.isCommandRunning)
    }

    /// The known limit in `FEATURES.md`, pinned: marks are not nested. Inside
    /// `ssh` to a shell that marks its own prompts, the remote commands are
    /// recorded, the `ssh` command itself never finishes, and its status
    /// lands on the last remote prompt.
    @Test("a remote shell's marks inside ssh are recorded as local commands")
    func nestedMarksAreFlattened() {
        var terminal = self.terminal(rows: 8)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ ssh h\r\n\u{1B}]133;C\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}h> false\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}h> exit\r\n\u{1B}]133;C\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ".utf8))
        let records = terminal.commandRecords.records
        #expect(records.map(\.promptRow) == [0, 1, 2, 3])
        #expect(records.map(\.exitStatus) == [nil, 1, 0, nil])
        #expect(records[0].isRunning)
        #expect(terminal.grid.line(2).mark == .promptSucceeded)
    }

    /// A shell that sends only `A` and `D` gives no sign of a command having
    /// run. `clear` there puts the cursor back on a top-row prompt, and its
    /// `D` must still count.
    @Test("without C, a D on the prompt's own row still finishes the command")
    func anADOnlyShellKeepsItsOutcomeAfterClear() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ clear\r\n\u{1B}[H\u{1B}[2J\u{1B}]133;D;0\u{1B}\\".utf8))
        #expect(terminal.commandRecords.last?.exitStatus == 0)
        #expect(terminal.takeFinishedCommand() == 0)
    }

    /// A second report for one command keeps the first, and is not a second
    /// finished command for the long-task notification.
    @Test("a second D for a finished command changes nothing")
    func aSecondDIsIgnored() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ false\r\n\u{1B}]133;C\u{1B}\\\u{1B}]133;D;1\u{1B}\\".utf8))
        #expect(terminal.takeFinishedCommand() == 1)
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        #expect(terminal.takeFinishedCommand() == nil)
        #expect(terminal.grid.line(0).mark == .promptFailed)
        #expect(terminal.commandRecords.last?.exitStatus == 1)
    }

    /// An empty line in fish draws a new prompt with no `D` for the old one.
    /// That prompt never ran anything; it is not a command left running.
    @Test("a prompt redrawn before anything ran is the same command")
    func aPromptWithNothingRunIsReused() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\> \u{1B}]133;B\u{1B}\\\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\> \u{1B}]133;B\u{1B}\\".utf8))
        let records = terminal.commandRecords.records
        #expect(records.count == 1)
        #expect(records.first?.promptRow == 1)
        #expect(records.first?.id == 0)
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

    /// The pasteboard reaches other applications, whose paste may not strip
    /// controls: an ESC there can close another terminal's bracketed paste.
    @Test("controls other than tab and newlines are stripped from the copy")
    func controlsAreStrippedFromTheCopy() {
        var terminal = self.terminal()
        let payload = Data("a\u{1B}[201~b\u{7F}c\u{9B}d\te\nf\rg".utf8).base64EncodedString()
        terminal.feed(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == "a[201~bcd\te\nf\rg")
    }

    @Test("tag characters survive only as part of a subdivision flag")
    func tagCharactersAreStrippedOutsideFlags() {
        var terminal = self.terminal()
        let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        let payload = Data("a\u{E0068}\u{E0069}b\(scotland)\u{E0068}c\u{206A}d".utf8).base64EncodedString()
        terminal.feed(Array("\u{1B}]52;c;\(payload)\u{1B}\\".utf8))
        #expect(terminal.takeClipboardCopy() == "ab\(scotland)cd")
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

    // MARK: - Command records

    @Test("a completed command gets a stable id and every field")
    func completedCommandRecordIsPopulated() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]7;file:///tmp\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        let records = terminal.commandRecords.records
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == 0)
        #expect(record.exitStatus == 0)
        #expect(!record.isRunning)
        #expect(!record.didFail)
        #expect(record.workingDirectory == "/tmp")
        #expect(record.outputStartRow != nil)
    }

    @Test("a running command has no exit status and counts as running")
    func runningCommandHasNoExitStatusYet() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ sleep 5\r\n\u{1B}]133;C\u{1B}\\".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.isRunning)
        #expect(record.exitStatus == nil)
    }
}
