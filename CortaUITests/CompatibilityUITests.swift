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

/// The real Neovim TUI exercises startup probes and coloured diagnostic underlines.
final class CompatibilityUITests: XCTestCase {
    @MainActor func testNeovimDiagnosticAndTerminalHealth() throws {
        continueAfterFailure = false
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/nvim") else {
            throw XCTSkip("Neovim is required for this real-program acceptance check")
        }
        let stage = try UIFixtures.stage("compatibility")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("nvim-shell").path
        app.launch()
        defer { app.terminate() }
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "missing_value"), evaluatedWith: terminal)
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        let diagnostic = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        diagnostic.name = "407-neovim-coloured-diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Terminal"), evaluatedWith: terminal)
        waitForExpectations(timeout: 20)
        let health = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        health.name = "407-neovim-terminal-health"
        health.lifetime = .keepAlways
        add(health)
    }

    @MainActor func testAppearanceChangesReportOnceToTheChild() throws {
        continueAfterFailure = false
        let stage = try UIFixtures.stage("compatibility-scheme")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("scheme-shell").path
        app.launch()
        defer { app.terminate() }
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "READY"), evaluatedWith: terminal)
        waitForExpectations(timeout: 10)
        let menu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        menu.click()
        menu.menuItems["Settings…"].click()
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.outlines.firstMatch.staticTexts["Appearance"].click()
        let mode = settings.popUpButtons["appearance-mode"]
        let reports = stage.appendingPathComponent("reports.txt")
        for (choice, expected) in [("Light", "1b5b3f3939373b326e"), ("Dark", "1b5b3f3939373b316e")] {
            mode.click()
            mode.menuItems[choice].click()
            let observed = NSPredicate { _, _ in
                (try? String(contentsOf: reports, encoding: .utf8).contains(expected)) == true
            }
            expectation(for: observed, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let actual = try String(contentsOf: reports, encoding: .utf8)
        XCTAssertEqual(actual, "1b5b3f3939373b326e\n1b5b3f3939373b316e\n")
    }

}
