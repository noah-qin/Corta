import XCTest

/// M4.4 and M4.7, against the live app: ⌘F opens the search bar and Esc
/// closes it; ⌘T adds a native tab (a second window in the tab group).
final class SearchAndTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandFOpensTheSearchBarAndEscapeClosesIt() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)
        let searchField = window.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "⌘F must show the search bar")

        // A query that cannot match: the bar reports it rather than hanging.
        searchField.typeText("zzz-no-such-string")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(
            searchField.waitForExistence(timeout: 2), "Esc must dismiss the search bar")
    }

    @MainActor
    func testCommandTOpensATab() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)

        // A native tab group exposes its tabs as radio buttons; the window
        // count stays 1 because the new session is a tab, not a window.
        // A native tab group exposes its tabs as `.tab`-type children whose
        // accessible label reports the count ("Tab bar, 2 tabs.").
        let tabGroup = window.tabGroups.firstMatch
        XCTAssertTrue(tabGroup.waitForExistence(timeout: 5), "⌘T must open a tab bar")
        let twoTabs = NSPredicate(format: "label CONTAINS '2 tabs'")
        expectation(for: twoTabs, evaluatedWith: tabGroup)
        waitForExpectations(timeout: 5)
    }

    /// Every ⌘T used to take a chrome height off the shared window frame —
    /// four tabs collapsed a 451pt window to the 49pt minimum — because
    /// inserting `.fullSizeContentView` re-derives the frame from the
    /// content size and a tab, unlike a standalone window, never overwrites
    /// the frame afterwards.
    ///
    /// The tab bar appearing does grow the frame once, by its own height, so
    /// that the panes keep their row count; after that the frame is fixed.
    @MainActor
    func testTabsDoNotShrinkTheWindow() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let beforeAnyTab = window.frame

        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let withTabBar = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            withTabBar.height, beforeAnyTab.height,
            "the tab bar must not eat into the window's height")

        for tab in 2...4 {
            app.typeKey("t", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let frame = app.windows.firstMatch.frame
            XCTAssertEqual(
                frame.height, withTabBar.height, accuracy: 1,
                "tab \(tab) resized the window: \(frame) vs \(withTabBar)")
            XCTAssertEqual(
                frame.width, withTabBar.width, accuracy: 1,
                "tab \(tab) resized the window: \(frame) vs \(withTabBar)")
        }
    }
}
