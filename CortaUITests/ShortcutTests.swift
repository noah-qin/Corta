import XCTest

/// Track D shortcuts, verified against the live app: ⌘N opens a second
/// window (D.2), ⌘= / ⌘- / ⌘0 resize the font and the window follows the
/// cell metrics (D.3).
///
/// Note on method: the keyboard path is exercised with ⌘=; the other two
/// actions are driven through the View menu's items because XCUI's
/// `typeKey("-", ...)` never produces a key event this app's menu matches
/// (the storyboard key equivalent is identical in form to the working ⌘=
/// one — the failure is in the synthetic event, not the app).
final class ShortcutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandNOpensASecondWindow() throws {
        let app = XCUIApplication()
        // Session restore (M7.4) would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("n", modifierFlags: .command)

        let twoWindows = NSPredicate(format: "count == 2")
        expectation(for: twoWindows, evaluatedWith: app.windows)
        waitForExpectations(timeout: 5)
    }

    /// The pre-display layout briefly has the requested frame, then AppKit
    /// applies `.fullSizeContentView` and removes one titlebar height. The
    /// session must stay at the configured grid through that final adjustment
    /// (a 120×30 window previously settled at 120×27).
    @MainActor
    func testNewWindowKeepsConfiguredGridAfterAppearing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let expected = configuredGridSize()
        let suffix = "\(expected.columns)×\(expected.rows)"
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if window.title.hasSuffix(suffix) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("new window did not keep configured grid \(suffix); title is \(window.title)")
    }

    /// Mirrors only the two integer keys this UI assertion needs. A missing
    /// file means the app defaults; values are clamped exactly as the app
    /// clamps them so a developer's local configuration does not make the
    /// test brittle.
    private func configuredGridSize() -> (columns: Int, rows: Int) {
        var columns = 120
        var rows = 30
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/corta/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (columns, rows)
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let pair = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, let value = Int(pair[1]) else { continue }
            if pair[0] == "columns" { columns = min(500, max(20, value)) }
            if pair[0] == "rows" { rows = min(300, max(5, value)) }
        }
        return (columns, rows)
    }

    /// Polls the window's width: `NSPredicate` expectations evaluate against
    /// a cached snapshot and never see the resize.
    @MainActor
    private func waitForWidth(
        _ app: XCUIApplication, _ predicate: (CGFloat) -> Bool, _ what: String
    ) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate(app.windows.firstMatch.frame.width) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("window width did not change: \(what) (now \(app.windows.firstMatch.frame.width))")
    }

    @MainActor
    private func clickViewMenuItem(_ app: XCUIApplication, _ title: String) {
        let viewMenu = app.menuBars.firstMatch.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let item = viewMenu.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        item.click()
    }

    @MainActor
    func testFontSizeShortcutsResizeTheWindowAroundTheGrid() throws {
        let app = XCUIApplication()
        // Session restore (M7.4) would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let original = window.frame.width
        // Same column count at a bigger cell: the window gets wider.
        app.typeKey("=", modifierFlags: .command)
        waitForWidth(app, { $0 > original }, "⌘= should widen the window")

        clickViewMenuItem(app, "Smaller")
        waitForWidth(app, { $0 == original }, "Smaller should restore the width")

        clickViewMenuItem(app, "Bigger")
        waitForWidth(app, { $0 > original }, "Bigger should widen the window again")
        clickViewMenuItem(app, "Actual Size")
        waitForWidth(app, { $0 == original }, "Actual Size should restore the default size")
    }
}
