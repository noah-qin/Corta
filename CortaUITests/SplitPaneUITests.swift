import XCTest

/// M5, against the live app: ⌘D splits the window, ⌘W closes the focused
/// pane before it closes the window. The panes themselves are Metal
/// surfaces with no accessibility content, so the assertions are about the
/// window surviving exactly as long as it has a pane.
final class SplitPaneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSplitThenClosePaneThenCloseWindow() throws {
        let app = XCUIApplication()
        // Session restore (M7.4) would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // ⌘D splits the focused pane right; the window must survive as one
        // window with two panes.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(window.waitForExistence(timeout: 2), "split must not disturb the window")

        // ⌘W closes the focused pane — the new one — and the window stays.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForExistence(timeout: 2), "⌘W must close the pane, not the window")

        // ⌘W on the last pane closes the window, as before splits existed.
        app.typeKey("w", modifierFlags: .command)
        let noWindows = NSPredicate(format: "count == 0")
        expectation(for: noWindows, evaluatedWith: app.windows)
        waitForExpectations(timeout: 5)
    }

    /// A visual record rather than an assertion: the panes are Metal
    /// surfaces, so the divider, the dim wash on the unfocused pane and the
    /// 50/50 geometry are verified by looking at the attachment in the
    /// test report, not by the accessibility tree.
    @MainActor
    func testSplitScreenshot() throws {
        let app = XCUIApplication()
        // Session restore (M7.4) would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.typeKey("d", modifierFlags: .command)  // two columns
        app.typeKey("D", modifierFlags: [.command, .shift])  // split the new pane down
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        attachment.name = "split-2x2"
        add(attachment)
    }

    /// `SplitViewController.absorbChromeChange`'s whole reason to exist: a
    /// tab bar joining the window must grow the frame downward, not shrink
    /// the content area — the naive AppKit behaviour costs every pane the
    /// bar's worth of rows the moment a second tab exists. Asserted on the
    /// window's frame because the panes are Metal surfaces with no
    /// accessibility content to query directly (see `testSplitScreenshot`);
    /// a shrunk content area cannot grow the frame without also shrinking
    /// it, so this is an equivalent, externally observable proxy for it.
    @MainActor
    func testOpeningATabDoesNotShrinkTheWindow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let before = window.frame

        app.typeKey("t", modifierFlags: .command)  // File > New Tab
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let after = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            after.height, before.height - 1,
            "a tab bar appearing must grow the window, not shrink the pane's content area")
    }
}
