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

    /// The window builds without a pane attached — `rebuild()` degrades to
    /// the "no pane" message rather than crashing, the same honest-
    /// degradation rule the rest of B07/B08 already follows.
    @Test func historyWindowBuildsWithNoPaneAttached() {
        let controller = CommandHistoryController.shared
        #expect(controller.window != nil)
    }
}
