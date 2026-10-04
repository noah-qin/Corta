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

final class InputSourceIndicatorUITests: XCTestCase {
    @MainActor func testToolbarLongInputExecutionAndSettings() throws {
        continueAfterFailure = false
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous) }
        let stage = try stage(appearance: "light")
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = application(stage: stage)
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let badge = app.staticTexts["input-source-indicator"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)
        // The launched grid agrees with the child, and a full screen of
        // output still scrolls normally with the native overlay installed.
        app.typeText("stty size\n")
        expectation(for: NSPredicate { _, _ in
            (app.textViews.firstMatch.value as? String)?.contains("18 60") == true
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        app.typeText("for i in {1..24}; do echo line-$i; done\n")
        expectation(for: NSPredicate { _, _ in
            (app.textViews.firstMatch.value as? String)?.contains("line-24") == true
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertFalse((app.textViews.firstMatch.value as? String)?.contains("\nline-1\n") == true)
        app.typeKey(.home, modifierFlags: .shift)
        waitForAbsence(badge)
        app.typeKey(.end, modifierFlags: .shift)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.typeText("clear\n")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let initial = badge.frame
        XCTAssertGreaterThan(initial.minX, window.frame.midX)
        attach(window, name: "input-source-light")
        // Toolbar position never changes as the command grows or the caret moves.
        app.typeText(String(repeating: "x", count: 53))
        XCTAssertTrue(badge.exists)
        XCTAssertEqual(badge.frame.minY, initial.minY, accuracy: 1)
        let avoided = badge.frame
        XCTAssertEqual(avoided.maxX, initial.maxX, accuracy: 1)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(badge.frame.minY, avoided.minY, accuracy: 1)
        attach(window, name: "input-source-long-command")
        app.typeKey("c", modifierFlags: .control)
        app.typeText("sleep 15\n")
        waitForAbsence(badge)
        app.typeKey("c", modifierFlags: .control)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        // A real alternate-screen program must suppress even the persistent mode.
        app.typeText("printf '\\033[?1049h'; sleep 15; printf '\\033[?1049l'\n")
        waitForAbsence(badge)
        app.typeKey("c", modifierFlags: .control)
        app.typeText("printf '\\033[?1049l'\n")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click(); appMenu.menuItems["Settings…"].click()
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        waitForAbsence(badge)
        settings.outlines.firstMatch.staticTexts["Keyboard & Mouse"].click()
        let mode = settings.popUpButtons["input-source-indicator-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5), settings.debugDescription)
        mode.click(); mode.menuItems["Off"].click()
        let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(config.contains("input-source-indicator = off"))
        mode.click(); mode.menuItems["While entering commands"].click()
        let position = settings.popUpButtons["input-source-indicator-position"]
        XCTAssertTrue(position.exists)
        position.click(); position.menuItems["Right edge of command line"].click()
        XCTAssertTrue(try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
            .contains("input-source-indicator-position = prompt"))
        position.click(); position.menuItems["Window toolbar"].click()
        let color = settings.textFields["input-source-direct-color"]
        XCTAssertTrue(color.exists)
        color.click(); color.typeText("#52b788"); color.typeKey(.return, modifierFlags: [])
        let updated = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(updated.contains("input-source-direct-color = #52b788"))
        attach(settings, name: "input-source-settings")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(app.textViews.count, 2)
        XCTAssertEqual(app.staticTexts.matching(identifier: "input-source-indicator").count, 1)
        attach(app.windows.firstMatch, name: "input-source-split")
    }

    @MainActor func testDarkAppearanceAndFallbackWithoutIntegration() throws {
        let stage = try stage(appearance: "dark")
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = application(stage: stage)
        let shell = stage.appendingPathComponent("plain-shell")
        try "#!/bin/sh\nexec /bin/sh --noprofile --norc -i\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        app.launchEnvironment["SHELL"] = shell.path
        app.launchEnvironment["PS1"] = "demo ❯ "
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["input-source-indicator"].waitForExistence(timeout: 5))
        attach(app.windows.firstMatch, name: "input-source-dark-fallback")
    }

    @MainActor func testInstalledCJKInputSourcesUpdateWithoutTyping() throws {
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer { TISSelectInputSource(previous) }
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            throw XCTSkip("No input source inventory")
        }
        func property(_ source: TISInputSource, _ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let chosen = ["com.apple.inputmethod.SCIM.", "com.apple.inputmethod.TCIM.",
            "com.apple.inputmethod.Kotoeri.", "com.apple.inputmethod.Korean."].compactMap { prefix in
                sources.first { property($0, kTISPropertyInputSourceID)?.hasPrefix(prefix) == true }
            }
        guard !chosen.isEmpty else { throw XCTSkip("No enabled built-in CJK source; no sources installed for testing") }
        let stage = try stage(appearance: "light")
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = application(stage: stage)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        for (index, source) in chosen.enumerated() {
            XCTAssertEqual(TISSelectInputSource(source), noErr)
            let name = try XCTUnwrap(property(source, kTISPropertyLocalizedName))
            let badge = app.staticTexts["input-source-indicator"]
            expectation(for: NSPredicate { _, _ in badge.exists && badge.label.contains(name) }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            attach(app.windows.firstMatch, name: "input-source-cjk-\(index)")
        }
    }

    @MainActor func testOptionalPromptPositionAvoidsLongCommands() throws {
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous) }
        let stage = try stage(appearance: "light")
        defer { try? FileManager.default.removeItem(at: stage) }
        let configURL = stage.appendingPathComponent("config")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        try (config + "input-source-indicator-position = prompt\n").write(to: configURL, atomically: true, encoding: .utf8)
        let app = application(stage: stage)
        app.launch(); app.activate()
        defer { app.terminate() }
        let badge = app.staticTexts["input-source-indicator"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let initial = badge.frame
        app.typeText(String(repeating: "x", count: 53))
        expectation(for: NSPredicate { _, _ in badge.exists && badge.frame.minY > initial.minY + 3 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(badge.frame.maxX, initial.maxX, accuracy: 1)
        attach(app.windows.firstMatch, name: "input-source-prompt-avoidance")
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
    @MainActor private func attach(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func stage(appearance: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corta-input-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "appearance = \(appearance)\ncolumns = 60\nrows = 18\nrestore-windows = false\nfont-size = 14\n".write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "PROMPT='demo ❯ '\nRPROMPT=''\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return directory
    }
    @MainActor private func application(stage: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["ZDOTDIR"] = stage.path
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        return app
    }
}
