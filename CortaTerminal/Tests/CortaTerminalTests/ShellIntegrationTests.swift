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

/// OSC 133 and OSC 52 — two things the child can tell the terminal that it
/// would otherwise have to guess at or could not hear at all.
@Suite struct ShellIntegrationTests {
    func terminal(rows: Int = 4, columns: Int = 20, scrollback: Int = 100) -> Terminal {
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
    func marksSurviveScrollingIntoHistory() throws {
        var terminal = self.terminal(rows: 3)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\prompt\r\n\u{1B}]133;C\u{1B}\\".utf8))
        for index in 0..<10 { terminal.feed(Array("line \(index)\r\n".utf8)) }
        terminal.feed(Array("\u{1B}]133;D;1\u{1B}\\".utf8))
        let marked = terminal.grid.promptRows
        #expect(marked.count == 1)
        let row = try #require(terminal.grid.line(atAbsoluteRow: marked[0]))
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
        // A shell that sends only A and D: the command line ends with Enter.
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ true\r\n\u{1B}]133;D\u{1B}\\".utf8))
        #expect(terminal.grid.line(0).mark == .promptSucceeded)
    }

    /// `clear` is `ESC[H ESC[2J` between its own C and D. Before #165 the
    /// erase kept every mark, and the D coloured the now-empty row `clear`
    /// was typed on: rules down blank rows under the fresh prompt.
    @Test("clear leaves no mark on the rows it erased")
    func clearDropsTheMarksItErases() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ true\r\n\u{1B}]133;C\u{1B}\\\u{1B}]133;D;0\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ clear\r\n\u{1B}]133;C\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\\u{1B}]133;A\u{1B}\\$ ".utf8))
        #expect(terminal.grid.line(0).mark == .prompt)
        for row in 1..<6 {
            #expect(terminal.grid.line(row).mark == .none, "row \(row)")
        }
    }

    /// zsh's and bash's ⌃L erase the screen and repaint the prompt at the top
    /// without a new `A`. The erase took the prompt's mark, so before this the
    /// next command's outcome was drawn nowhere.
    @Test("after ⌃L the next command is marked on the repainted prompt")
    func aPromptRepaintedByCtrlLIsMarked() throws {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ true\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("\u{1B}[H\u{1B}[2J$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("false\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptFailed)
        let last = try #require(terminal.commandRecords.lastCompleted)
        #expect(last.promptRow == 0)
        #expect(last.exitStatus == 1)
        #expect(last.promptEndColumn == 2)
    }

    /// Clear Screen keeps the waiting prompt visible at the top.
    @Test("after Clear Screen the next command is marked where it was typed")
    func clearScreenMovesTheWaitingPrompt() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ true\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        terminal.clearScreen()
        #expect(terminal.grid[0, 0].scalar == 0x24)
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 2))
        terminal.feed(Array("ls\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptSucceeded)
        #expect(terminal.grid.promptRows == [0])
    }

    @Test("Clear Screen preserves empty input, text and a cursor inside the input",
          arguments: ["", "echo hello", "echo hello\u{1B}[5D"])
    func clearScreenPreservesEditor(input: String) throws {
        var terminal = self.terminal(rows: 6, columns: 30)
        terminal.feed(Array("history\r\noutput\r\n\u{1B}]133;A\u{7}\u{1B}[32muser ❯ \u{1B}[0m\u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array(input.utf8))
        let before = terminal.grid
        let column = try #require(terminal.promptEndPosition).column
        let count = terminal.commandRecords.records.count
        terminal.clearScreen()
        #expect(terminal.grid.line(0) == before.line(2))
        #expect(terminal.grid.cursor == Cursor(row: 0, column: before.cursor.column))
        #expect(terminal.promptEndPosition?.column == column)
        #expect(terminal.commandRecords.last?.promptEndColumn == column)
        #expect(terminal.commandRecords.records.count == count)
        #expect(!terminal.isCommandRunning)
        #expect(terminal.grid.line(1).isEmpty)
        // Repeated clearing at the top must retain the editor too.
        terminal.clearScreen()
        #expect(terminal.grid.line(0) == before.line(2))
        terminal.feed(Array("X".utf8))
        #expect(terminal.grid[0, before.cursor.column].scalar == 0x58)
    }

    @Test("Clear Screen preserves multiline prompts, wrapped wide input and rows below the cursor")
    func clearScreenPreservesMultilineEditor() {
        var terminal = self.terminal(rows: 10, columns: 12)
        let screen = "old\r\nold\r\n\u{1B}]133;A\u{7}location\r\n❯ "
            + "\u{1B}]133;B\u{7}你好abcdefghi\r\nsecond e\u{301}\u{1B}[1A\u{1B}[3G"
        terminal.feed(Array(screen.utf8))
        let before = terminal.grid
        terminal.clearScreen()
        for row in 0..<8 { #expect(terminal.grid.line(row) == before.line(row + 2)) }
        #expect(terminal.grid.cursor == Cursor(row: before.cursor.row - 2, column: before.cursor.column))
        #expect(terminal.grid.pendingWrap == before.pendingWrap)
        #expect(terminal.inputPromptRow == terminal.grid.absoluteRow(ofScreenRow: 0))
        #expect(terminal.promptEndPosition == nil, "multiline prompt must not acquire a single-line boundary")
    }

    @Test("Clear Screen retains deferred wrap and scrollback without appending cleared output")
    func clearScreenPreservesWrapAndHistory() {
        var terminal = self.terminal(rows: 4, columns: 8)
        terminal.feed(Array("history\r\nold\r\nold\r\nold\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}123456".utf8))
        let before = terminal.grid
        #expect(before.pendingWrap)
        terminal.clearScreen()
        #expect(terminal.grid.line(0) == before.line(3))
        #expect(terminal.grid.pendingWrap)
        #expect(terminal.grid.scrollback.totalPushed == before.scrollback.totalPushed)
        #expect(terminal.grid.line(atAbsoluteRow: 0) == before.line(atAbsoluteRow: 0))
        terminal.feed(Array("Z".utf8))
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 1))
        #expect(terminal.grid[1, 0].scalar == 0x5A)
    }

    @Test("Clear Screen leaves alternate programs and oversized editors intact")
    func clearScreenDoesNotEraseOwnedCanvas() {
        var terminal = self.terminal(rows: 3)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}one\r\ntwo\r\nthree\r\nfour".utf8))
        let editor = terminal.grid
        terminal.clearScreen()
        for row in 0..<3 { #expect(terminal.grid.line(row) == editor.line(row)) }
        #expect(terminal.grid.cursor == editor.cursor)
        terminal.feed(Array("\u{1B}]133;C\u{7}\u{1B}[?1049hVIM".utf8))
        let alternate = terminal.grid
        let records = terminal.commandRecords
        terminal.clearScreen()
        for row in 0..<3 { #expect(terminal.grid.line(row) == alternate.line(row)) }
        #expect(terminal.grid.cursor == alternate.cursor)
        #expect(terminal.commandRecords == records)
        #expect(terminal.isCommandRunning)
    }

    @Test("Clear Screen during output retains the running command's boundaries")
    func clearScreenDuringCommand() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("old\r\n\u{1B}]133;A\u{7}$ run\u{1B}]133;B\u{7}\r\n\u{1B}]133;C\u{7}output".utf8))
        let records = terminal.commandRecords
        terminal.clearScreen()
        #expect(terminal.isCommandRunning)
        #expect(terminal.commandRecords == records)
        terminal.feed(Array("more\r\n\u{1B}]133;D;0\u{7}".utf8))
        #expect(terminal.commandRecords.lastCompleted?.promptRow == records.last?.promptRow)
        #expect(terminal.commandRecords.lastCompleted?.exitStatus == 0)
    }

    /// The session's first prompt: no `C` has arrived yet, and the repaint's
    /// `B` is sign enough that the prompt, not a command, was cleared.
    @Test("⌃L at the session's first prompt still marks the next command")
    func ctrlLBeforeAnyCommandIsMarked() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("\u{1B}[H\u{1B}[2J$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("false\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptFailed)
    }

    /// Erase first, home second: the prompt moves where its repaint lands,
    /// not to the row the cursor sat on during the erase — that one is empty.
    @Test("an erase before the cursor moves home marks the repainted row")
    func eraseThenHomeMarksTheRepaintedRow() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("a\r\nb\r\nc\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("\u{1B}[2J\u{1B}[H$ \u{1B}]133;B\u{7}".utf8))
        terminal.feed(Array("false\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptFailed)
        #expect(terminal.grid.line(3).mark == .none)
    }

    /// Clear Screen before any command: the prompt's `B` shows it is waiting.
    @Test("Clear Screen at the session's first prompt still marks the next command")
    func clearScreenBeforeAnyCommandIsMarked() {
        var terminal = self.terminal(rows: 6)
        terminal.feed(Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        terminal.clearScreen()
        terminal.feed(Array("ls\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptSucceeded)
    }
}
