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

@MainActor
final class CortaSpaceConversationUITests: XCTestCase {
    private let first = "claude --resume 3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912"
    private let second = "claude --resume 019eee77-052d-7530-af09-17a140e08123"
    private let third = "codex resume 2b20121e-9a9b-43cb-b12e-fde980cb41e0"

    private func launch(_ scenario: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["CORTA_UI_FIXTURES"],
                                 "Prepare stage-ui-fixtures.sh and pass TEST_RUNNER_CORTA_UI_FIXTURES")
        let stage = URL(fileURLWithPath: root).appendingPathComponent("space-conversation-" + scenario)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("config").path))
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["ZDOTDIR"] = stage.path
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.toolbars.buttons["Show Space"].click()
        return app
    }

    private func waitForText(_ text: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let terminal = app.textViews.matching(predicate).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 12), text)
    }

    private func expectNote(_ text: String, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["Undo"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Space-conversation-" + (text.hasPrefix("Each") ? "many" : "one")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSingleConversationWaitsForReturnAndCanBeFilledAgain() throws {
        let app = try launch("one")
        defer { app.terminate() }
        waitForText(first, in: app)
        expectNote("This conversation is filled in. Press Return to continue. Delete the line to skip it.", in: app)
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains {
            ($0.value as? String)?.contains("USER-EXECUTED") == true
        })
        let panel = app.groups.matching(identifier: "Corta.Space.Panel").firstMatch
        panel.click()
        app.typeKey("u", modifierFlags: .control)
        panel.buttons["Panel Actions"].click()
        app.menuItems["Fill Conversation Again"].click()
        waitForText(first, in: app)
        app.typeKey(.return, modifierFlags: [])
        waitForText("USER-EXECUTED-CLAUDE --resume", in: app)
    }

    func testEachPaneAndLaterShownCodexKeepTheirOwnConversation() throws {
        let app = try launch("many")
        defer { app.terminate() }
        waitForText(first, in: app)
        waitForText(second, in: app)
        let note = "Each pane has its own conversation filled in. Press Return to continue. "
            + "Delete that line to skip it."
        expectNote(note, in: app)
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains {
            ($0.value as? String)?.contains("USER-EXECUTED") == true
        })
        app.outlines["Corta.Space.Sidebar"].staticTexts["Conversation C"].click()
        app.typeKey(.return, modifierFlags: .command)
        waitForText(third, in: app)
        expectNote("Press Return to continue this conversation.", in: app)
    }

    func testInvalidUUIDLeavesPromptBlankAndShowsNoFillNote() throws {
        let app = try launch("invalid")
        defer { app.terminate() }
        waitForText("demo ❯", in: app)
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains {
            ($0.value as? String)?.contains("--resume") == true
        })
        XCTAssertFalse(app.otherElements["Corta.Space.Note"].exists)
    }
}
