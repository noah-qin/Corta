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

final class AgentPaneTransferUITests: XCTestCase {
    @MainActor func testCommandOutputOpensThePickedAgentDraftWithoutSending() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous) }
        let stage = try UIFixtures.stage("agent-pane-transfer")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)

        let terminal = app.textViews.firstMatch
        startAgent("primary", in: terminal)
        app.typeKey("e", modifierFlags: [.command, .shift])
        let field = app.textViews["composer-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Please explain the failure.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)
        UIFixtures.requireFixturePrompt(in: app)
        startAgent("secondary", in: terminal)
        app.typeKey("t", modifierFlags: .command)
        UIFixtures.requireFixturePrompt(in: app)
        terminal.typeText("echo transfer-fixture; false\r")
        waitForText("\ntransfer-fixture", in: terminal)

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        app.typeText("send last command output to agent pane")
        app.typeKey(.return, modifierFlags: [])
        let targets = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-pane-target-"))
        XCTAssertTrue(targets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(targets.count, 2)
        app.typeText("primary")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(field.waitForExistence(timeout: 5))
        waitForText("transfer-fixture", in: field)
        let draft = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(draft.hasPrefix("Please explain the failure.\n\n[from "))
        XCTAssertTrue(draft.contains(" · $ echo transfer-fixture; false · exit 1]"))
        XCTAssertTrue(draft.contains("\n```\ntransfer-fixture\n```"))
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        XCTAssertTrue((terminal.value as? String)?.contains("Agent ready") == true)
        XCTAssertFalse((terminal.value as? String)?.contains("transfer-fixture") == true)

        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        waitForText("Received paste: Please explain the failure.", in: terminal)
        XCTAssertTrue((terminal.value as? String)?.contains("transfer-fixture") == true)
        XCTAssertFalse((terminal.value as? String)?.contains("Received input outside paste") == true)
    }

    @MainActor private func startAgent(_ directory: String, in terminal: XCUIElement) {
        terminal.typeText("cd \"$ZDOTDIR/\(directory)\"; \"$ZDOTDIR/corta-agent\" \"$ZDOTDIR/agent-input\"\r")
        waitForText("Agent ready", in: terminal)
    }

    @MainActor private func waitForText(_ text: String, in element: XCUIElement) {
        let match = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 10), .completed)
    }
}
