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

final class DirectoryCompletionUITests: XCTestCase {
    @MainActor func testFoldersFilterAndTabOnlyFills() throws {
        continueAfterFailure = false
        let previousInputSource = LatinInputSource.select()
        defer { LatinInputSource.restore(previousInputSource) }
        // Prepared by stage-ui-fixtures.sh: the runner cannot write folders
        // the app's shell can see.
        let stage = try UIFixtures.stage("directory-completion")
        let folder = stage.appendingPathComponent("Demo")
        let app = UIFixtures.app(stage: stage, runner: Self.self)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        app.typeText("cd '\(folder.path)'\nclear\ntrue\nfalse\nsleep 10\n")
        app.typeKey("c", modifierFlags: .control)
        app.typeText("cd ")
        let preview = app.staticTexts["directory-completion-preview"]
        let alternatives = app.staticTexts["directory-completion-candidates"]
        XCTAssertTrue(alternatives.waitForExistence(timeout: 5))
        XCTAssertTrue(alternatives.label.contains("Alpha/"))
        XCTAssertTrue(alternatives.label.contains("Another/"))
        XCTAssertFalse(preview.exists)
        let choicesScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        choicesScreenshot.lifetime = .keepAlways
        add(choicesScreenshot)
        XCTAssertFalse(app.buttons["Alpha/"].exists)
        app.typeText("Al")
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertFalse(alternatives.exists)
        let alphaSuffix = NSPredicate(format: "label == %@", "pha/")
        expectation(for: alphaSuffix, evaluatedWith: preview)
        waitForExpectations(timeout: 3)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(preview.waitForExistence(timeout: 1))
        // A suggestion is not executable input until accepted, and Tab does not run it.
        app.typeKey("c", modifierFlags: .control)
        app.typeText("cd A")
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(alternatives.waitForExistence(timeout: 3))
        app.typeKey(.rightArrow, modifierFlags: [])
        expectation(for: NSPredicate(format: "label == %@", "nother/"), evaluatedWith: preview)
        waitForExpectations(timeout: 3)
        app.typeKey(.leftArrow, modifierFlags: [])
        expectation(for: NSPredicate(format: "label == %@", "lpha/"), evaluatedWith: preview)
        waitForExpectations(timeout: 3)
        // Up recalls the previous shell command; Down restores the unfinished cd.
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertFalse(preview.waitForExistence(timeout: 1))
        XCTAssertFalse(alternatives.exists)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "label == %@", "lpha/"), evaluatedWith: preview)
        waitForExpectations(timeout: 3)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(preview.waitForExistence(timeout: 1))
        XCTAssertFalse(alternatives.exists)
        app.typeKey("c", modifierFlags: .control)
        app.typeText("cd A")
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        app.typeKey(.tab, modifierFlags: .shift)
        app.typeText("l")
        // Shift+Tab must not accept Alpha/; the input can still narrow A to Al.
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        expectation(for: alphaSuffix, evaluatedWith: preview)
        waitForExpectations(timeout: 3)
        app.typeKey("c", modifierFlags: .control)
        app.typeText("cd .")
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "label == %@", "hidden/"), evaluatedWith: preview)
        waitForExpectations(timeout: 3)
    }
}
