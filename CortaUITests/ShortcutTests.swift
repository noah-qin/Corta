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
        // Session restore would otherwise carry the previous
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
    /// (a 120×30 window must not settle at 120×27) — checked here as frame
    /// *stability*: once the window first reports a frame, that frame must not
    /// change again. A late correction is exactly a frame that changes after
    /// the window already looked settled; a window that was simply wrong the
    /// whole time, never correcting, would not be caught by this alone, but
    /// that shape of bug is what `SplitPaneUITests` and the `CONFORMANCE.md`
    /// §4.4.2 manual pass (`stty size` against a live window) are for.
    ///
    /// Three more direct checks were tried first and ruled out, each for a
    /// reason specific to this test machine rather than to Corta:
    /// 1. The window title carries the grid size only for the ~1.5s after
    ///    `resizeSessionToFitView` actually *changes* `lastRequestedSize`
    ///    (`PaneWindowTitle.noteTransientSizeChange`). On a normal launch,
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
    /// 3. Reading `AXHelp` ("%d rows by %d columns...") through
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

    /// A font change keeps the window where it is: the top edge stays and
    /// the size moves by less than a cell, so the new grid fills it
    /// (`SplitViewController.fitWindowToWholeCells`). Smaller and Actual
    /// Size land on the frame the window opened at, whole cells of the
    /// configured font.
    @MainActor
    func testFontSizeShortcutsFitTheWindowInPlace() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let original = window.frame

        app.typeKey("=", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let zoomed = window.frame
        assertFittedInPlace(zoomed, from: original, "⌘=")

        clickViewMenuItem(app, "Smaller")
        waitForFrame(app, original, "Smaller should land on the frame the window opened at")

        clickViewMenuItem(app, "Bigger")
        waitForFrame(app, zoomed, "Bigger should land on the same frame as ⌘= did")
        clickViewMenuItem(app, "Actual Size")
        waitForFrame(app, original, "Actual Size should land on the frame the window opened at")
    }

    /// Less than a cell either way, top edge fixed. A cell at the sizes
    /// these tests use is under 20pt in both directions.
    @MainActor
    private func assertFittedInPlace(
        _ frame: CGRect, from original: CGRect, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(frame.minY, original.minY, accuracy: 0.5, "\(what) moved the top edge", file: file, line: line)
        XCTAssertEqual(frame.minX, original.minX, accuracy: 0.5, "\(what) moved the left edge", file: file, line: line)
        XCTAssertLessThan(abs(frame.width - original.width), 20, "\(what): \(frame) vs \(original)", file: file, line: line)
        XCTAssertLessThan(abs(frame.height - original.height), 20, "\(what): \(frame) vs \(original)", file: file, line: line)
    }

    /// Polls: `NSPredicate` expectations evaluate against a cached snapshot
    /// and never see the resize.
    @MainActor
    private func waitForFrame(_ app: XCUIApplication, _ expected: CGRect, _ what: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.windows.firstMatch.frame == expected { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("\(what): now \(app.windows.firstMatch.frame), expected \(expected)")
    }
}
