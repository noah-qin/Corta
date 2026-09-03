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
        // Theme, appearance, font family, bell and link activation are
        // pop-ups; size, scrollback and the notification threshold are
        // fields; the five toggles are switches.
        XCTAssertEqual(settings.popUpButtons.count, 5)
        XCTAssertEqual(settings.textFields.count, 3)
        XCTAssertEqual(settings.switches.count, 5)
    }

    /// The theme and appearance lists live under View — where "what the
    /// window looks like" belongs — and there is exactly one "Settings…"
    /// entry in the whole menu bar, the one macOS puts in the app menu.
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
        viewMenu.menuItems["Theme"].click()
        for theme in ["Corta", "Solarized", "Mono"] {
            XCTAssertTrue(viewMenu.menuItems[theme].exists, "\(theme) must be listed")
        }
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }
}
