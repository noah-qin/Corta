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

/// Search and tabs, against the live app: ⌘F opens the search bar and Esc
/// closes it; ⌘T adds a native tab (a second window in the tab group).
final class SearchAndTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandFOpensTheSearchBarAndEscapeClosesIt() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
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
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
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

    /// A ⌘T must not take a chrome height off the shared window frame —
    /// four tabs would collapse a 451pt window to the 49pt minimum. The
    /// risk is real because inserting `.fullSizeContentView` re-derives the
    /// frame from the content size, and a tab, unlike a standalone window,
    /// never overwrites the frame afterwards.
    ///
    /// The tab bar appearing does grow the frame once, by its own height, so
    /// that the panes keep their row count; after that the frame is fixed.
    @MainActor
    func testTabsDoNotShrinkTheWindow() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
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
