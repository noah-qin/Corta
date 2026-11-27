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

extension AgentStatusUITests {
    @MainActor
    func testBackgroundStatusAndAgentsJump() throws {
        let stage = try UIFixtures.stage("agents")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("auto-shell").path
        app.launchEnvironment["TEST_AGENT_MARKER"] = UUID().uuidString
        app.launchEnvironment["TEST_AGENT_MODE"] = "signal"
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 5)
        // Status must arrive while the first tab's render loop is paused.
        app.menuBars.menuBarItems["Window"].click()
        let agents = app.menuBars.menuItems["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3))
        agents.hover()
        let waiting = app.menuBars.menuItems.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@", "Waiting for you", "Permission")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 3))
        XCTAssertTrue(waiting.title.hasSuffix(" · Waiting < 1 min"))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "agent-background-waiting-menu-and-tab"; shot.lifetime = .keepAlways; add(shot)
        waiting.click()
        let terminal = app.textViews.firstMatch
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "Background permission fixture"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        // Palette lists agent panes and can jump with the same row identity.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Permission")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasSuffix(" · Waiting < 1 min"))
        let preview = app.descendants(matching: .any)["agent-screen-preview"]
        XCTAssertFalse(preview.exists)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.hasPrefix("Screen text"))
        XCTAssertTrue(preview.label.contains("Background permission fixture"))
        XCTAssertFalse(row.label.contains("Background permission fixture"))
        let previewShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        previewShot.name = "agent-background-waiting-preview"
        previewShot.lifetime = .keepAlways
        add(previewShot)
        row.click()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        app.typeKey("c", modifierFlags: .control)
    }
}
