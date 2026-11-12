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

/// Two of the launched-app checks of `CONFORMANCE.md` §4.4 that were done by
/// hand before each release: a restored tabbed window (item 6) and a
/// translated menu bar (item 7). Item 5, keys and menu actions reaching the
/// pane, is `ShortcutTests` and `ContextMenuAndPasteUITests`.
final class LaunchedAppChecksUITests: XCTestCase {
    /// Three tabs, the first split and not selected, the second selected, each
    /// named so the order can be read back; ⌘Q, relaunch with restore on.
    /// The window comes back as one window, tabs in saved order, the saved tab
    /// selected, and the background tab's split there when it is first shown.
    @MainActor func testRestoredTabbedWindowKeepsOrderSelectionAndBackgroundSplit() throws {
        continueAfterFailure = false
        let app = UIFixtures.app(stage: try UIFixtures.stage("tab-restore"), runner: Self.self)
        // Restore stays on for both launches: `CORTA_RESTORE_WINDOWS=0` also stops
        // the arrangement being saved. A rerun on the same stage reopens the last
        // run's windows, so the first launch closes back to one window, one tab
        // and one pane before building the arrangement.
        app.launchEnvironment.removeValue(forKey: "CORTA_RESTORE_WINDOWS")
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<12 {
            let strip = app.windows.firstMatch.tabGroups["tab-strip"]
            let tabCount = strip.exists ? strip.radioButtons.count : 1
            let panes = app.windows.firstMatch.buttons.matching(identifier: "pane.close").count
            if app.windows.count == 1, tabCount <= 1, panes <= 1 { break }
            app.typeKey("w", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            if app.windows.count == 0 {
                app.typeKey("n", modifierFlags: .command)
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            }
        }
        UIFixtures.requireFixturePrompt(in: app)
        let window = app.windows.firstMatch
        XCTAssertEqual(app.windows.count, 1, "could not close back to one window")

        app.typeKey("d", modifierFlags: .command)
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: window.buttons.matching(identifier: "pane.close"))
        waitForExpectations(timeout: 5)
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let strip = window.tabGroups["tab-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let tabs = strip.radioButtons
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)

        let names = ["alpha-split", "beta-selected", "gamma"]
        for (index, name) in names.enumerated() {
            // Ending a rename hands the keyboard back to the terminal on a later
            // turn of the run loop, and selecting a tab moves it to that tab's
            // pane: both are given time before the field is opened.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            tabs.element(boundBy: index).click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            tabs.element(boundBy: index).doubleClick()
            let editor = app.textFields["tab-title-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 3), "no rename field on tab \(index)")
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(name)
            editor.typeKey(.return, modifierFlags: [])
            let renamed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", name), object: tabs.element(boundBy: index))
            XCTAssertEqual(
                XCTWaiter.wait(for: [renamed], timeout: 3), .completed,
                "tab \(index) not renamed; labels: \(tabs.allElementsBoundByIndex.map(\.label)),"
                    + " field still open: \(editor.exists)")
        }
        tabs.element(boundBy: 1).click()
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: tabs.element(boundBy: 1))
        waitForExpectations(timeout: 3)

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "⌘Q did not quit")

        app.launch()
        let restored = app.windows.firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        let restoredTabs = restored.tabGroups["tab-strip"].radioButtons
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: restoredTabs)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.windows.count, 1, "the tabs came back as separate windows")
        for (index, name) in names.enumerated() {
            XCTAssertTrue(restoredTabs.element(boundBy: index).label.hasPrefix(name),
                          "tab \(index) is \(restoredTabs.element(boundBy: index).label), not \(name)")
        }
        XCTAssertEqual(restoredTabs.element(boundBy: 1).value as? Int, 1, "the saved tab is not selected")
        XCTAssertEqual(restoredTabs.element(boundBy: 0).value as? Int, 0)
        XCTAssertEqual(restored.buttons.matching(identifier: "pane.close").count, 1, "the selected tab is not split")

        restoredTabs.element(boundBy: 0).click()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: restored.buttons.matching(identifier: "pane.close"))
        waitForExpectations(timeout: 5)
        attach(restored.screenshot(), name: "restored-background-split")
    }

    /// Launched in Simplified Chinese, the menu bar's own titles are
    /// translated, not only the menus beneath them.
    @MainActor func testMenuBarTitlesAreTranslatedInSimplifiedChinese() throws {
        continueAfterFailure = false
        let app = UIFixtures.app(stage: try UIFixtures.stage("menu-language"), runner: Self.self)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let bar = app.menuBars.firstMatch
        for title in ["文件", "编辑", "显示", "窗口", "帮助"] {
            XCTAssertTrue(bar.menuBarItems[title].waitForExistence(timeout: 5), "no \(title) in the menu bar")
        }
        for english in ["File", "Edit", "View", "Window", "Help"] {
            XCTAssertFalse(bar.menuBarItems[english].exists, "\(english) is still English")
        }
        let edit = bar.menuBarItems["编辑"]
        edit.click()
        XCTAssertGreaterThan(edit.menuItems.count, 0)
        XCTAssertFalse(edit.menuItems["Paste"].exists, "the Edit menu's items are still English")
        app.typeKey(.escape, modifierFlags: [])
        attach(app.windows.firstMatch.screenshot(), name: "zh-Hans-window")
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
