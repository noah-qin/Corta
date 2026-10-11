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

import AppKit
import XCTest

final class SessionEndedUITests: XCTestCase {
    @MainActor func testCompactExitCardFitsAndCanStartANewSession() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous) }
        for fixture in ["session-ended", "session-ended-narrow"] {
            let app = UIFixtures.app(stage: try UIFixtures.stage(fixture), runner: Self.self, usingTestTarget: true)
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            UIFixtures.requireFixturePrompt(in: app)
            app.typeKey("d", modifierFlags: .control)
            let card = app.groups["Corta.SessionEnded"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.frame.contains(card.frame))
            XCTAssertLessThanOrEqual(card.frame.width, 561)
            let restart = card.buttons["New Session"]
            let close = card.buttons["Close Pane"]
            XCTAssertTrue(restart.isHittable && close.isHittable)
            XCTAssertFalse(restart.frame.intersects(close.frame))
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = fixture
            shot.lifetime = .keepAlways
            add(shot)
            restart.click()
            let start = app.sheets.buttons["Start"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            start.click()
            expectation(for: NSPredicate { _, _ in !card.exists }, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            UIFixtures.requireFixturePrompt(in: app)
            app.typeKey("d", modifierFlags: .control)
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            card.buttons["Close Pane"].click()
            expectation(for: NSPredicate { _, _ in app.windows.count == 0 }, evaluatedWith: nil)
            waitForExpectations(timeout: 10)
            app.terminate()
        }
    }
}
