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

/// UI06 / UI07 — how the menus group what they carry: the Shell menu's
/// create / move / resize order, and the single Theme submenu that holds
/// both the appearance choice and the theme list.
@MainActor
struct MenuStructureTests {
    @Test("Shell keeps frequent actions direct and all other tools in shallow submenus")
    func shellMenuGrouping() throws {
        let main = try #require(NSApp.mainMenu)
        let shell = try #require(main.items.first { $0.title == L10n.text("menu.shell") }?.submenu)
        let visible = shell.items.filter { !$0.isSeparatorItem && !$0.isHidden }
        #expect(visible.count <= 12)
        for command in [TerminalCommand.splitRight, .splitDown, .reopenClosedPane, .clearScreen, .secureKeyboardEntry] {
            #expect(visible.contains { $0.action == command.action })
        }
        let groups: [(String, [TerminalCommand])] = [
            ("menu.focus", [.focusLeft, .focusRight, .focusUp, .focusDown]),
            ("menu.commandsAndOutput", [.previousCommand, .nextCommand, .previousFailedCommand,
                .nextFailedCommand, .copyLastCommandOutput, .snapshotRunningCommandOutput,
                .exportCommandOutput, .openFileReferenceInCommand, .searchCommandHistory]),
            ("menu.workingDirectory", [.revealWorkingDirectory, .copyWorkingDirectoryPath,
                .changeDirectoryToParent, .changeDirectoryToProjectRoot,
                .openParentDirectoryInNewPane, .openProjectRootInNewPane, .browseRemoteFiles]),
            ("menu.paneLayout", [.zoomPane, .growPaneHorizontally, .shrinkPaneHorizontally,
                .growPaneVertically, .shrinkPaneVertically, .equalizePanes]),
            ("menu.terminalState", [.clearHistory, .resetTerminal, .reconnectRemote]),
        ]
        for (key, commands) in groups {
            let submenu = try #require(shell.items.first { $0.title == L10n.text(key) }?.submenu)
            #expect(submenu.items.map(\.action) == commands.map { Optional($0.action) })
            #expect(submenu.items.allSatisfy { $0.submenu == nil })
        }
    }

    @Test("View has one Theme submenu holding appearance, then themes")
    func themeSubmenuHoldsAppearanceAndThemes() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let view = try #require(
            mainMenu.items.first(where: { $0.title == L10n.text("menu.view") })?.submenu,
            "the menu bar must carry a View menu")

        // No second submenu for the same decision: the standalone
        // Appearance submenu is gone.
        #expect(
            view.items.allSatisfy { $0.submenu?.title != L10n.text("settings.tab.appearance") })

        let themeItem = view.items.first {
            $0.submenu?.title == L10n.text("settings.label.theme")
        }
        let theme = try #require(themeItem?.submenu, "the View menu must carry the Theme submenu")
        let appearanceCount = Configuration.Appearance.allCases.count
        #expect(theme.items.count > appearanceCount + 1)

        // Appearance choices head the list, tagged for `selectAppearance`.
        for (index, item) in theme.items.prefix(appearanceCount).enumerated() {
            #expect(item.action == #selector(AppDelegate.selectAppearance(_:)))
            #expect(item.tag == index)
        }
        #expect(theme.items[appearanceCount].isSeparatorItem)
        for item in theme.items.dropFirst(appearanceCount + 1) {
            #expect(item.action == #selector(AppDelegate.selectTheme(_:)))
        }
    }
}

@MainActor
extension NSMenu {
    var descendantItems: [NSMenuItem] {
        items.flatMap { [$0] + ($0.submenu?.descendantItems ?? []) }
    }
}
