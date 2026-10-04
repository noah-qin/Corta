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

final class CursorAndWindowUITests: XCTestCase {
    @MainActor func testOversizedWindowsAndRestorationFitVisibleScreen() throws {
        continueAfterFailure = false
        let stage = try makeStage(config: "columns = 500\nrows = 300\nrestore-windows = true\ncursor-shape = bar\ncursor-blink = true\n")
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = makeApp(stage: stage)
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        assertFitsVisibleScreen(window.frame)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5))
        for window in app.windows.allElementsBoundByIndex { assertFitsVisibleScreen(window.frame) }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        for window in app.windows.allElementsBoundByIndex { assertFitsVisibleScreen(window.frame) }
    }

    @MainActor func testCursorSettingsPersistAndBlinkInLiveWindow() throws {
        continueAfterFailure = false
        let stage = try makeStage(config: "appearance = light\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-shape = bar\ncursor-blink = true\n")
        defer { try? FileManager.default.removeItem(at: stage) }
        let app = makeApp(stage: stage)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click()
        appMenu.menuItems["Settings…"].click()
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.outlines.firstMatch.staticTexts["Appearance"].click()
        let shape = settings.popUpButtons["cursor-shape"]
        XCTAssertTrue(shape.waitForExistence(timeout: 5), settings.debugDescription)
        shape.click()
        shape.menuItems["Underline"].click()
        let blink = settings.switches["cursor-blink"]
        XCTAssertTrue(blink.exists)
        blink.click()
        let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(config.contains("cursor-shape = underline"))
        XCTAssertTrue(config.contains("cursor-blink = false"))
        blink.click()
        shape.click()
        shape.menuItems["Bar"].click()
        let settingsShot = XCTAttachment(screenshot: settings.screenshot())
        settingsShot.name = "cursor-settings"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let window = app.windows.firstMatch
        // A quiet neutral shell makes cursor blinking the only canvas change.
        Thread.sleep(forTimeInterval: 1)
        var captures: [Data] = []
        for index in 0..<5 {
            let shot = window.screenshot().pngRepresentation
            captures.append(shot)
            let attachment = XCTAttachment(data: shot, uniformTypeIdentifier: "public.png")
            attachment.name = "cursor-phase-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertGreaterThan(Set(captures).count, 1, "the enabled cursor must blink on an idle terminal")
    }

    private func makeStage(config: String) throws -> URL {
        let stage = URL(fileURLWithPath: "/private/tmp/corta-ui-stages", isDirectory: true).appendingPathComponent("corta-cursor-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try config.write(to: stage.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "PROMPT='demo ❯ '\n".write(to: stage.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return stage
    }

    @MainActor private func makeApp(stage: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["ZDOTDIR"] = stage.path
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        return app
    }

    @MainActor private func assertFitsVisibleScreen(_ frame: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let fits = NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame
            let rect = CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height)
            return rect.insetBy(dx: -2, dy: -2).contains(frame)
        }
        XCTAssertTrue(fits, "window \(frame) must fit a display's visible area", file: file, line: line)
    }
}
