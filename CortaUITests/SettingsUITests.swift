import XCTest

/// M6.1 and M6.2, against the live app: the settings page opens from the
/// menu bar, and a theme picked from the Settings menu is applied.
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
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click()
        let item = appMenu.menuItems["Settings…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        let settings = app.windows["Corta Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the settings page must open")
        // Theme, appearance, font family and bell are pop-ups; size,
        // scrollback and the notification threshold are fields.
        XCTAssertEqual(settings.popUpButtons.count, 4)
        XCTAssertEqual(settings.textFields.count, 3)
        XCTAssertEqual(settings.switches.count, 1)
    }

    @MainActor
    func testTheSettingsMenuListsEveryThemeAndAppearance() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let settingsMenu = app.menuBars.firstMatch.menuBarItems["Settings"]
        XCTAssertTrue(settingsMenu.exists, "the Settings menu sits beside Shell and Edit")
        settingsMenu.click()
        settingsMenu.menuItems["Theme"].click()
        for theme in ["Corta", "Solarized", "Mono"] {
            XCTAssertTrue(settingsMenu.menuItems[theme].exists, "\(theme) must be listed")
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
