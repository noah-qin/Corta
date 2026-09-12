import AppKit
import Testing

@testable import Corta

/// B08 — the new commands' place in the Shell menu and the command table,
/// the same shape `CommandOutputWiringTests` already checks for B07's
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
            #expect(shell.items.contains { $0.action == command.action })
        }
    }

    /// The window builds without a pane attached — `CommandHistoryModel
    /// .rows` degrades to empty and `noPaneMessage` explains why, rather
    /// than crashing, the same honest-degradation rule the rest of
    /// B07/B08 already follows.
    @Test func historyWindowBuildsWithNoPaneAttached() {
        let controller = CommandHistoryController.shared
        #expect(controller.window != nil)
        #expect(controller.model.rows.isEmpty)
        #expect(controller.model.noPaneMessage != nil)
    }
}

/// B10 — `CommandHistoryModel`'s filter composition, now that it is a plain
/// object a test can drive directly instead of logic embedded in the
/// AppKit view-building code it used to live inside.
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

    @Test func actionsWithoutAMatchingRecordDoNothing() {
        let model = CommandHistoryModel()
        model.find(id: 999)  // no pane at all — must not crash
        model.fill(id: 999)
        model.run(id: 999)
    }
}
