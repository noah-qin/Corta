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

import XCTest

/// Settings, against the live app: the settings page opens from
/// the menu bar, and the theme and appearance lists are where a user would
/// look for them.
///
/// The ⌘, shortcut is verified by the menu item carrying it (visible in the
/// app menu) rather than by typing it: XCUITest's `typeKey` does not deliver
/// a punctuation key equivalent, and a test that cannot press the key cannot
/// tell a broken shortcut from a broken harness.
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsPageOpensFromTheAppMenu() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = appMenu.menuItems["Settings…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        // Found by identifier: the window is named after the selected page.
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the settings page must open")
        // A sidebar of categories (an outline), the System Settings layout
        // that replaced the three-tab `TabView` once General outgrew a tab.
        let sidebar = settings.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3), "the settings page must have a sidebar")
        for category in [
            "General", "Appearance", "Terminal", "Keyboard & Mouse", "Shortcuts",
            "Quick Terminal", "Connections", "Privacy & Security",
        ] {
            XCTAssertTrue(
                sidebar.staticTexts[category].waitForExistence(timeout: 3),
                "the \(category) category must exist")
        }

        // The Appearance pane: light-or-dark, the font family and the size
        // field. The theme pop-up is hidden while only one theme is offered.
        // The catalog's string, letter for letter ("Light or dark"); whether
        // SwiftUI exposes a `Picker`'s label as a static text or as the
        // pop-up's own label varies by release, so any element will do.
        sidebar.staticTexts["Appearance"].click()
        XCTAssertTrue(
            settings.descendants(matching: .any)["Light or dark"].waitForExistence(timeout: 3),
            "the Appearance pane must show the light-or-dark picker")

        // Terminal: the bell is a pop-up-style picker, the search defaults
        // are switches, scrollback is a field.
        sidebar.staticTexts["Terminal"].click()
        XCTAssertTrue(settings.switches.firstMatch.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(settings.popUpButtons.count, 1)
        XCTAssertGreaterThanOrEqual(settings.switches.count, 2)

        // Keyboard & Mouse: link activation and the mouse-override modifier
        // are pickers.
        sidebar.staticTexts["Keyboard & Mouse"].click()
        XCTAssertTrue(settings.popUpButtons.firstMatch.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(settings.popUpButtons.count, 2)
    }

    /// The theme and appearance choices live under View — where "what the
    /// window looks like" belongs — in one Theme submenu, and there is
    /// exactly one "Settings…" entry in the whole menu bar, the one macOS
    /// puts in the app menu.
    @MainActor
    func testThemeAndAppearanceAreListedUnderView() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        XCTAssertFalse(
            app.menuBars.firstMatch.menuBarItems["Settings"].exists,
            "the second Settings entry must be gone")

        let viewMenu = app.menuBars.firstMatch.menuBarItems["View"]
        XCTAssertTrue(viewMenu.exists)
        viewMenu.click()
        XCTAssertFalse(
            viewMenu.menuItems["Appearance"].exists,
            "appearance is a row in the Theme submenu, not a second submenu")
        viewMenu.menuItems["Theme"].click()
        // The appearance choice heads the same submenu — one place for the
        // whole light-or-dark-and-which-theme decision.
        for appearance in ["Follow System", "Light", "Dark"] {
            XCTAssertTrue(
                viewMenu.menuItems[appearance].waitForExistence(timeout: 3),
                "\(appearance) must be a row in the Theme submenu")
        }
        // One offered theme (`Theme.builtIn`). The others stay defined and
        // resolvable by name for a config file that asks for them; they are
        // not recommended from the menu.
        XCTAssertTrue(viewMenu.menuItems["Corta"].exists, "the built-in theme must be listed")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }
}
