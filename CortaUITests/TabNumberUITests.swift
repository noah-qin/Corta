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

/// Tabs that show the same title carry their position number (#528), read
/// back through each tab's accessibility label, which carries the number
/// too: "zsh ~, tab 2".
final class TabNumberUITests: XCTestCase {
    @MainActor func testIdenticalTabsAreNumberedUntilOneChangesDirectory() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(previous) }
        let app = UIFixtures.app(stage: try UIFixtures.stage("tab-numbers"), runner: Self.self)
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        // A lone pane has no header (#527): the tab is the only place its
        // title shows.
        XCTAssertEqual(window.buttons.matching(identifier: "pane.close").count, 0)

        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let tabs = window.tabGroups["tab-strip"].radioButtons
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)
        for index in 0..<3 {
            let numbered = NSPredicate(format: "label ENDSWITH %@", ", tab \(index + 1)")
            expectation(for: numbered, evaluatedWith: tabs.element(boundBy: index))
        }
        waitForExpectations(timeout: 5)
        attach(window.screenshot(), name: "tab-numbers-identical")

        // ⌘2 shows the tab numbered 2; a `cd` there makes its title its own.
        app.typeKey("2", modifierFlags: .command)
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: tabs.element(boundBy: 1))
        waitForExpectations(timeout: 3)
        app.typeText("cd /tmp\r")
        expectation(
            for: NSPredicate(format: "NOT (label CONTAINS %@)", ", tab "), evaluatedWith: tabs.element(boundBy: 1))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(tabs.element(boundBy: 0).label.hasSuffix(", tab 1"), tabs.element(boundBy: 0).label)
        XCTAssertTrue(tabs.element(boundBy: 2).label.hasSuffix(", tab 3"), tabs.element(boundBy: 2).label)
        attach(window.screenshot(), name: "tab-numbers-one-unique")
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
