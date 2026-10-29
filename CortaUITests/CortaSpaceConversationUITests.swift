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
        if scenario == "real", let home = ProcessInfo.processInfo.environment["CORTA_CONVERSATION_REAL_HOME"] {
            app.launchEnvironment["HOME"] = home
            for key in ["CORTA_CONVERSATION_REAL_CLAUDE", "CORTA_CONVERSATION_REAL_CODEX"] {
                let childKey = key == "CORTA_CONVERSATION_REAL_CLAUDE" ? "TEST_REAL_CLAUDE" : "TEST_REAL_CODEX"
                app.launchEnvironment[childKey] = ProcessInfo.processInfo.environment[key]
            }
        }
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
        let note = "Each pane has its resume command filled in. Press Return to continue. "
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

    func testRealCLIsFillTheirRecordedCommandsAfterAppRelaunch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CORTA_CONVERSATION_REAL_CLAUDE"] != nil,
              environment["CORTA_CONVERSATION_REAL_CODEX"] != nil else {
            throw XCTSkip("Opt in with authenticated installed Claude/Codex and a trusted real fixture cwd")
        }
        let app = try launch("real")
        defer { app.terminate() }
        let panels = app.groups.matching(identifier: "Corta.Space.Panel")
        XCTAssertEqual(panels.count, 2)
        let root = try XCTUnwrap(environment["CORTA_UI_FIXTURES"])
        let file = URL(fileURLWithPath: root)
            .appendingPathComponent("space-conversation-real/ApplicationSupport/space.json")
        let predicate = NSPredicate { _, _ in
            guard let entries = try? self.realConversations(in: file) else { return false }
            return entries.count == 2 && entries[0].source == "sessionRecord" && entries[1].kind == "codex"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                                    timeout: 20), .completed)
        let entries = try realConversations(in: file)
        XCTAssertEqual(entries.first?.source, "sessionRecord")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.toolbars.buttons["Show Space"].click()
        for entry in entries {
            let prefix = entry.kind == "claude" ? "claude --resume" : "codex resume"
            waitForText(prefix + (entry.id.map { " " + $0.lowercased() } ?? ""), in: app)
        }
        expectNote("Each pane has its resume command filled in. Press Return to continue. "
                   + "Delete that line to skip it.", in: app)
    }

    private struct RealConversation: Decodable {
        let kind: String
        let id: String?
        let source: String
    }

    private func realConversations(in file: URL) throws -> [RealConversation] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let projects = try XCTUnwrap(object?["projects"] as? [[String: Any]])
        let sessions = try XCTUnwrap(projects.first?["sessions"] as? [[String: Any]])
        return try sessions.compactMap { session in
            guard let identity = session["conversation"] else { return nil }
            return try JSONDecoder().decode(RealConversation.self,
                                           from: JSONSerialization.data(withJSONObject: identity))
        }
    }

    func testInvalidUUIDFallsBackToPickerWithoutExecuting() throws {
        let app = try launch("invalid")
        defer { app.terminate() }
        waitForText("claude --resume", in: app)
        expectNote("The resume command is filled in. Press Return, then choose the conversation to continue. "
                   + "Delete the line to skip it.", in: app)
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains {
            let text = $0.value as? String ?? ""
            return text.contains("; echo bad") || text.contains("--continue") || text.contains("--last")
                || text.contains("USER-EXECUTED")
        })
        let panel = app.groups.matching(identifier: "Corta.Space.Panel").firstMatch
        panel.buttons["Panel Actions"].click()
        XCTAssertTrue(app.menuItems["Resume Source: picker"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMissingRecordsFillTwoIndependentPickers() throws {
        let app = try launch("pickers")
        defer { app.terminate() }
        let predicate = NSPredicate(format: "value CONTAINS %@", "claude --resume")
        let deadline = SuspendingClock.now + .seconds(12)
        while app.textViews.matching(predicate).count < 2, SuspendingClock.now < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(app.textViews.matching(predicate).count, 2)
        expectNote("Each pane has its resume command filled in. Press Return to continue. "
                   + "Delete that line to skip it.", in: app)
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains {
            let text = $0.value as? String ?? ""
            return text.contains("USER-EXECUTED") || text.contains("--continue") || text.contains("--last")
        })
    }
}
