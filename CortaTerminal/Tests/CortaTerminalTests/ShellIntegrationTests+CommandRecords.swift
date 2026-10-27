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
    @Test("a failed command's record says so")
    func failedCommandRecordDidFail() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\\u{1B}]133;C\u{1B}\\\u{1B}]133;D;1\u{1B}\\".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.didFail)
    }

    /// Each `A` starts a new record, keyed by a ever-increasing id rather
    /// than reused across commands — the identity records exist to give.
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
    /// "copy last command's output" exists to avoid.
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
        for row in 0..<(CommandRecordStore.defaultCapacity + 10) {
            store.begin(promptRow: row, workingDirectory: nil, at: Date())
        }
        #expect(store.records.count == CommandRecordStore.defaultCapacity)
        #expect(store.records.first?.id == 10)
        #expect(store.records.last?.id == CommandRecordStore.defaultCapacity + 9)
    }

    @Test("a store's capacity is configurable per instance")
    func recordStoreCapacityIsConfigurable() {
        var store = CommandRecordStore(capacity: 3)
        for row in 0..<5 {
            store.begin(promptRow: row, workingDirectory: nil, at: Date())
        }
        #expect(store.records.count == 3)
        #expect(store.records.map(\.id) == [2, 3, 4])
    }

    // MARK: - Command text recovery

    /// `promptEndColumn` is what `ViewController.commandLineText(grid:
    /// record:)` reads a historic command's own text back from — it has to
    /// land on the record itself, not just the live `PerformerState`, or a
    /// command already scrolled off the current prompt would have nowhere
    /// honest to read its start column from.
    @Test("the B mark's column is recorded on the command, not just the live state")
    func promptEndColumnLandsOnTheRecord() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\ls\r\n".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.promptEndColumn == 2)
    }

    /// A multi-line prompt whose `B` lands on a later row leaves the record
    /// honestly unable to say where the command starts, the same "under-
    /// estimate is the safe direction" rule `state.promptEndColumn` already
    /// follows.
    @Test("a B mark on a different row leaves promptEndColumn unset")
    func promptEndColumnUnsetForAWrappedPrompt() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\~/src\r\n\u{1B}]133;B\u{1B}\\$ ls\r\n".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.promptEndColumn == nil)
    }

    @Test("clearing command records empties the store without touching the grid")
    func clearCommandRecordsEmptiesTheStore() {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        #expect(!terminal.commandRecords.records.isEmpty)
        let textBefore = terminal.grid.logicalLine(containing: 0).text
        terminal.clearCommandRecords()
        #expect(terminal.commandRecords.records.isEmpty)
        #expect(terminal.grid.logicalLine(containing: 0).text == textBefore)
    }

    // MARK: - Prompt end position

    @Test("the prompt end column is where the cursor sits right after B")
    func promptEndColumnIsRecordedAtB() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8))
        let position = try #require(terminal.promptEndPosition)
        #expect(position.row == 0)
        #expect(position.column == 2)  // "$ " is two columns wide
    }

    @Test("typing after B does not move the recorded prompt end column")
    func typingDoesNotMoveThePromptEndColumn() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8))
        terminal.feed(Array("ls -la".utf8))
        let position = try #require(terminal.promptEndPosition)
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

    // MARK: - Command record search

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

    // MARK: - Remote context on command records

    /// A command begun while the pane refers to a remote host records that
    /// host on the command itself — the remote context can move on or be
    /// cleared while the command is still running, and the record must not.
    @Test("a command begun under a remote context records its host")
    func remoteCommandRecordsItsHost() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]7;file://build-box/srv/app\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ make\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.host == "build-box")
        // The remote path stays out of the local-only field, even though a
        // remote OSC 7 was the last directory report the pane saw.
        #expect(record.workingDirectory == nil)
    }

    @Test("a local command records no host")
    func localCommandRecordsNoHost() throws {
        var terminal = self.terminal()
        terminal.feed(Array("\u{1B}]7;file:///tmp\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\out\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\".utf8))
        let record = try #require(terminal.commandRecords.last)
        #expect(record.host == nil)
        #expect(record.workingDirectory == "/tmp")
    }

    @Test("records can be filtered by host")
    func recordsFilterByHost() {
        var store = CommandRecordStore()
        store.begin(promptRow: 0, workingDirectory: nil, host: "build-box", at: Date())
        store.finish(exitStatus: 0, endRow: 1, at: Date())
        store.begin(promptRow: 2, workingDirectory: "/tmp", at: Date())
        store.finish(exitStatus: 0, endRow: 3, at: Date())
        store.begin(promptRow: 4, workingDirectory: nil, host: "build-box", at: Date())
        store.finish(exitStatus: 1, endRow: 5, at: Date())
        #expect(store.records(onHost: "build-box").map(\.promptRow) == [4, 0])
        #expect(store.records(exitStatus: 1, host: "build-box").map(\.promptRow) == [4])
        #expect(store.records(onHost: "elsewhere").isEmpty)
    }

    @Test("a finished command clears bracketed paste a command's output turned on")
    func commandEndClearsBracketedPaste() {
        var terminal = Terminal(rows: 4, columns: 20)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ cat x\r\n\u{1B}]133;C\u{1B}\\".utf8))
        // The file's bytes, under a shell that never enables it itself.
        terminal.feed(Array("\u{1B}[?2004h".utf8))
        #expect(terminal.isBracketedPasteEnabled)
        terminal.feed(Array("\u{1B}]133;D;0\u{1B}\\\u{1B}]133;A\u{1B}\\$ ".utf8))
        #expect(!terminal.isBracketedPasteEnabled)
        // A line editor that supports it turns it back on after D.
        terminal.feed(Array("\u{1B}[?2004h".utf8))
        #expect(terminal.isBracketedPasteEnabled)
    }
}

extension ShellIntegrationTests {
    /// The limit is the user's setting, not terminal state: RIS replaced the
    /// store with one at the default capacity, so `command-history-limit = 0`
    /// started recording again after `reset`.
    @Test("a reset keeps the configured command-history limit", arguments: [0, 3])
    func resetKeepsHistoryLimit(limit: Int) {
        var terminal = Terminal(rows: 4, columns: 20, commandHistoryLimit: limit)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ".utf8))
        terminal.reset()
        #expect(terminal.commandRecords.capacity == limit)
        #expect(terminal.commandRecords.records.isEmpty)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ls\r\n\u{1B}]133;C\u{1B}\\".utf8))
        #expect(terminal.commandRecords.records.count == min(limit, 1))
    }
}
