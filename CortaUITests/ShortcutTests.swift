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
    /// session must stay at the configured grid through that final
    /// adjustment (a 120×30 window previously settled at 120×27) — checked
    /// here as frame *stability*: once the window first reports a frame,
    /// that frame must not change again. A late correction (the historical
    /// bug) is exactly a frame that changes after the window already
    /// looked settled; a window that was simply wrong the whole time, never
    /// correcting, would not be caught by this alone, but that shape of bug
    /// is what `SplitPaneUITests` and the `CONFORMANCE.md` §4.4.2 manual
    /// pass (`stty size` against a live window) are for.
    ///
    /// Three more direct checks were tried first and ruled out, each for a
    /// reason specific to this test machine rather than to Corta:
    /// 1. The window title carries the grid size only for the ~1.5s after
    ///    `resizeSessionToFitView` actually *changes* `lastRequestedSize`
    ///    (`ViewController.noteTransientSizeChange`). On a normal launch,
    ///    where the pre-display frame already lands at the configured grid
    ///    (the case this test exercises when nothing is broken), that
    ///    never fires — `lastRequestedSize` is seeded to the session's own
    ///    initial size, so the settled layout matching it is a no-op, not
    ///    a correction. A title-based version of this test timed out for
    ///    exactly that reason: it asserted a side effect of the fix rather
    ///    than the fix itself.
    /// 2. Typing `stty size` and reading the shell's echoed reply (through
    ///    the terminal's `AXValue`) sounded like the direct check, but
    ///    both `typeText` and per-character `typeKey` post virtual
    ///    keycodes, and this machine's active input source — Chinese
    ///    Pinyin (`com.apple.inputmethod.SCIM.ITABC`) — composes them into
    ///    Chinese candidates before Corta ever sees a byte, exactly as it
    ///    correctly would for a real Chinese-Pinyin user.
    /// 3. Reading `AXHelp` (M8.1's "%d rows by %d columns...") through
    ///    System Events sidesteps the keyboard, but the xctest runner
    ///    process has no Automation/TCC permission to drive System Events
    ///    at all — "Application isn't running" for an application that
    ///    plainly is, the characteristic misleading message a TCC denial
    ///    gives here — and granting it needs a one-time GUI prompt only a
    ///    human at this machine can approve.
    @MainActor
    func testNewWindowKeepsConfiguredGridAfterAppearing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let firstFrame = window.frame
        XCTAssertGreaterThan(firstFrame.width, 0)
        XCTAssertGreaterThan(firstFrame.height, 0)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let frame = window.frame
            XCTAssertEqual(
                frame, firstFrame,
                "window settled at \(firstFrame) then changed to \(frame) — a late "
                    + "correction, the historical 120×30-settles-at-120×27 bug's shape")
        }
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
