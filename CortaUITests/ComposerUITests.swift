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

/// The compose field (#540) in the launched app, against real zsh with
/// bracketed paste: ⇧⌘E opens it, Return is a newline, ⌘Return sends the
/// text to the prompt unsubmitted, and Esc closes it keeping the draft.
/// Typing selects a Latin layout for the test's duration; a real input
/// method's candidates are the launched-app check's.
final class ComposerUITests: XCTestCase {
    @MainActor private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(previous) }
        let stage = try UIFixtures.stage("context-paste-dangerous")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        return app
    }

    @MainActor private func waitForText(_ text: String, in element: XCUIElement) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testComposeSendsAMultilinePasteWithoutSubmittingIt() throws {
        let app = try launch()
        defer { app.terminate() }
        let terminal = app.textViews.firstMatch
        app.typeKey("e", modifierFlags: [.command, .shift])
        let field = app.textViews["composer-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Send"].exists)

        // Esc closes the field and keeps what was written for next time.
        field.typeText("draft kept")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "draft kept")

        // Return is a newline in the field; ⌘Return sends.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("echo composed-one\recho composed-two")
        XCTAssertEqual(field.value as? String, "echo composed-one\necho composed-two")
        record(app, name: "composer-open")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))

        // zsh holds a bracketed multi-line paste in its buffer: both lines are
        // at the prompt, and neither has run.
        waitForText("echo composed-two", in: terminal)
        let shown = terminal.value as? String ?? ""
        XCTAssertFalse(shown.contains("\ncomposed-one\n"), "the paste must not be submitted")
        XCTAssertFalse(app.buttons["Cancel"].exists, "a bracketed paste of two lines needs no warning")
        record(app, name: "composer-sent")
    }
}
