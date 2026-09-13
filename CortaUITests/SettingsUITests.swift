import XCTest

/// M6.1, M6.2 and M6.15, against the live app: the settings page opens from
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
        // Session restore (M7.4) would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = appMenu.menuItems["Settings…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        let settings = app.windows["Corta Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the settings page must open")
        // Three tabs in a native `TabView` — SwiftUI's own tab chrome
        // replaced the AppKit page's `NSToolbar` (a deliberate visual
        // change; see the PR that introduced this file's rewrite). A native
        // macOS `TabView` exposes its tab items as buttons inside a
        // `tabGroup`, not inside `toolbars` as the old `NSToolbar`-backed
        // page did.
        //
        // NOTE: this file could not be run in the environment that wrote
        // this rewrite (XCUITest automation times out there) — it is a
        // best-effort port of the assertions' *intent*, not a verified pass.
        let tabGroup = settings.tabGroups.firstMatch
        XCTAssertTrue(tabGroup.waitForExistence(timeout: 3), "the settings page must have a tab view")
        for tab in ["Appearance", "Terminal", "General"] {
            XCTAssertTrue(
                tabGroup.buttons[tab].waitForExistence(timeout: 3), "the \(tab) tab must exist")
        }

        // The Appearance pane: light-or-dark, the font family (a label, not
        // a picker — Corta ships one font) and the size field. The theme
        // pop-up is hidden while only one theme is offered.
        XCTAssertTrue(settings.staticTexts["Light or Dark"].waitForExistence(timeout: 3))

        tabGroup.buttons["Terminal"].click()
        // Bell and link activation are pop-up-style pickers; copy-on-select
        // and the clipboard-write toggle are switches; scrollback is a
        // field.
        XCTAssertTrue(settings.switches.firstMatch.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(settings.popUpButtons.count, 2)
        XCTAssertGreaterThanOrEqual(settings.switches.count, 2)
    }

    /// The theme and appearance choices live under View — where "what the
    /// window looks like" belongs — in one Theme submenu, and there is
    /// exactly one "Settings…" entry in the whole menu bar, the one macOS
    /// puts in the app menu.
    @MainActor
    func testThemeAndAppearanceAreListedUnderView() throws {
        let app = XCUIApplication()
        // Session restore (M7.4) would otherwise carry the previous
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
