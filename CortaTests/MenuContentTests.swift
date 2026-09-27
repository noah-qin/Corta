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

/// What the menus call things, and whether the promises
/// they make are kept.
///
/// `MenuShortcutTests` pins *which keys* the menu bar claims; this pins the
/// words: File's New is a new window under the same name the palette and the
/// shortcuts sheet use, and Corta Help leads somewhere real instead of the
/// storyboard template's `showHelp:` against a help book Corta never shipped.
@MainActor
struct MenuContentTests {
    /// Every item in the menu bar, depth-first.
    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map { items(in: $0) } ?? [])
        }
    }

    @Test("File's New names the window it opens, under the palette's name for the same command")
    func fileNewIsNewWindow() throws {
        let menu = try #require(NSApp.mainMenu)
        let new = try #require(
            Self.items(in: menu).first {
                $0.action == #selector(AppDelegate.newDocument(_:))
            },
            "the File menu must carry the new-window command")
        // One name everywhere: the menu item, the palette and the shortcuts
        // sheet all read `TerminalCommand.newWindow.title`. Compared against
        // the command's title rather than a literal, so the assertion holds
        // in every localization at once.
        #expect(new.title == TerminalCommand.newWindow.title)
        #expect(new.title == L10n.text("command.newWindow"))
    }

    /// The menu bar shows a top-level item by its *submenu's* title. Only
    /// the item was localised, so the bar read File / Shell / … in every
    /// language while everything beneath it was translated.
    @Test("every top-level menu's submenu title is the localised item title")
    func menuBarTitlesAreLocalised() throws {
        let menu = try #require(NSApp.mainMenu)
        for item in menu.items.dropFirst() {  // the app menu's title is the app's name
            let submenu = try #require(item.submenu, "top-level item \(item.title) has no submenu")
            #expect(submenu.title == item.title, "\(submenu.title) vs \(item.title)")
        }
    }

    @Test("Corta Help opens the documentation, not an empty help book")
    func cortaHelpHasARealDestination() throws {
        let menu = try #require(NSApp.mainMenu)
        let items = Self.items(in: menu)
        // The template action searches Help Viewer for a help book that does
        // not exist; no item in the bar may still send it.
        #expect(items.allSatisfy { $0.action != #selector(NSApplication.showHelp(_:)) })
        let cortaHelp = try #require(
            items.first {
                $0.action == #selector(AppDelegate.showHelpDocumentation(_:))
            },
            "the Help menu must keep a Corta Help item")
        #expect(cortaHelp.target === NSApp.delegate)
        #expect(AppDelegate.helpURL.scheme == "https")
        #expect(AppDelegate.helpURL.host == "github.com")
    }
}
