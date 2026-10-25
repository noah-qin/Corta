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
import Carbon
import XCTest

final class HistorySuggestionUITests: XCTestCase {
    @MainActor func testPreviewAcceptanceDismissalAndNativeCompletion() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(previous) }
        let stage = try UIFixtures.stage("history-suggestions")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        app.activate()
        _ = LatinInputSource.select()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        let preview = app.staticTexts["history-suggestion-preview"]
        let terminal = app.textViews.firstMatch
        func expectLine(_ text: String) {
            expectation(for: NSPredicate { _, _ in
                (terminal.value as? String)?.contains(text) == true
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        app.typeText("echo history-suggestion-proof\nclear\necho hist")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.label, "ory-suggestion-proof")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "history-suggestion"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.rightArrow, modifierFlags: [])
        expectLine("demo ❯ echo history-suggestion-proof")
        XCTAssertFalse(preview.exists)
        app.typeKey("u", modifierFlags: .control)
        app.typeText("echo hist")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.typeKey(.end, modifierFlags: [])
        expectLine("demo ❯ echo history-suggestion-proof")
        app.typeKey("u", modifierFlags: .control)
        app.typeText("echo hist")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(preview.waitForExistence(timeout: 1))
        expectLine("demo ❯ echo hist")
        app.typeKey("u", modifierFlags: .control)
        app.typeText("cat \(stage.path)/Al")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [])
        expectLine("demo ❯ cat \(stage.path)/Alpha/")
        XCTAssertFalse((terminal.value as? String)?.contains("cat \(stage.path)/Alternative" ) == true)
    }

    @MainActor func testPinyinCompositionHidesHistorySuggestion() throws {
        continueAfterFailure = false
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
            let pinyin = sources.first(where: { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String == "com.apple.inputmethod.SCIM.ITABC"
        }) else { throw XCTSkip("No enabled Pinyin input source") }
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        addTeardownBlock { TISSelectInputSource(previous) }
        _ = LatinInputSource.select()
        let stage = try UIFixtures.stage("history-suggestions")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        app.activate()
        _ = LatinInputSource.select()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        app.typeText("echo hist")
        let preview = app.staticTexts["history-suggestion-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(TISSelectInputSource(pinyin), noErr)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("nihao")
        XCTAssertFalse(preview.waitForExistence(timeout: 1))
        let composition = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        composition.name = "history-pinyin-composition"
        composition.lifetime = .keepAlways
        add(composition)
        let candidate = app.dialogs.buttons.firstMatch
        guard candidate.waitForExistence(timeout: 5) else {
            throw XCTSkip("System Pinyin candidate AX is unavailable under synthesized input; no native composition/commit result claimed. Review the retained window capture manually.")
        }
        let chosen = candidate.label
        XCTAssertTrue(chosen.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        expectation(for: NSPredicate { _, _ in
            (app.textViews.firstMatch.value as? String)?.contains(chosen) == true
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }
}
