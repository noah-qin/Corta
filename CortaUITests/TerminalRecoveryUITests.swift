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
import AppKit

final class TerminalRecoveryUITests: XCTestCase {
    @MainActor func testResetThenSynchronizedOutputRecoversItsCanvas() throws {
        continueAfterFailure = false
        let original = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(original) }
        defer { LatinInputSource.restore(original) }
        guard let fixtures = ProcessInfo.processInfo.environment["CORTA_UI_FIXTURES"] else {
            throw XCTSkip("Prepare fixtures using stage-ui-fixtures.sh")
        }
        let stage = URL(fileURLWithPath: fixtures).appendingPathComponent("terminal-recovery").path
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage
        app.launchEnvironment["ZDOTDIR"] = stage
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        app.typeText("printf '\\033[?2026hFIRST\\033[?2026l'; sleep 2; printf '\\033c\\033[?2026hSECOND\\n'\n")
        let second = NSPredicate(format: "value CONTAINS %@", "SECOND\ndemo")
        expectation(for: second, evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 2)
        let held = terminal.screenshot().pngRepresentation
        app.typeText("printf 'ISSUE228-%s\\n' 'INPUT-LIVE'\n")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "ISSUE228-INPUT-LIVE"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.4)
        let stillHeld = terminal.screenshot().pngRepresentation
        XCTAssertNotEqual(canvasPixels(held), canvasPixels(stillHeld), "timeout must release the hold so later input changes the canvas")
        let heldShot = XCTAttachment(data: stillHeld, uniformTypeIdentifier: "public.png")
        heldShot.name = "issue228-sync-recovered"; heldShot.lifetime = .keepAlways; add(heldShot)
        app.typeText("printf 'ISSUE228-%s\\n' 'NEXT-FRAME'\n")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "ISSUE228-NEXT-FRAME"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        let released = terminal.screenshot().pngRepresentation
        XCTAssertNotEqual(canvasPixels(stillHeld), canvasPixels(released), "the next command must also update the recovered canvas")
        let releasedShot = XCTAttachment(data: released, uniformTypeIdentifier: "public.png")
        releasedShot.name = "issue228-sync-next-frame"; releasedShot.lifetime = .keepAlways; add(releasedShot)
    }

    @MainActor private func canvasPixels(_ png: Data) -> Data {
        let bitmap = NSBitmapImageRep(data: png)!
        // Terminal's accessibility frame includes the titlebar. Compare raw
        // canvas pixels so process-title updates and PNG metadata do not count.
        let image = bitmap.cgImage!.cropping(to: CGRect(x: 20, y: 160,
            width: bitmap.pixelsWide - 40, height: bitmap.pixelsHigh - 180))!
        let canvas = NSBitmapImageRep(cgImage: image)
        return Data(bytes: canvas.bitmapData!, count: canvas.bytesPerRow * canvas.pixelsHigh)
    }

    @MainActor func testIdleAndOcclusionRecovery() throws {
        continueAfterFailure = false
        let originalSource = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(originalSource) }
        defer { LatinInputSource.restore(originalSource) }
        guard let fixtures = ProcessInfo.processInfo.environment["CORTA_UI_FIXTURES"] else {
            throw XCTSkip("Prepare fixtures using stage-ui-fixtures.sh")
        }
        let stage = URL(fileURLWithPath: fixtures).appendingPathComponent("terminal-recovery").path
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage
        app.launchEnvironment["ZDOTDIR"] = stage
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        let before = window.screenshot().pngRepresentation
        // Idle is the stimulus; assertions wait on observable output.
        Thread.sleep(forTimeInterval: 15)
        app.typeText("printf 'ISSUE228-%s\\n' 'LIVE-IDLE'\n")
        let idleOutput = NSPredicate(format: "value CONTAINS %@", "ISSUE228-LIVE-IDLE")
        expectation(for: idleOutput, evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        let after = window.screenshot().pngRepresentation
        XCTAssertNotEqual(before, after, "the canvas must update after idle")
        let idleShot = XCTAttachment(data: after, uniformTypeIdentifier: "public.png")
        idleShot.name = "issue228-after-idle"; idleShot.lifetime = .keepAlways; add(idleShot)

        window.buttons[XCUIIdentifierMinimizeWindow].click()
        Thread.sleep(forTimeInterval: 10)
        app.activate()
        // AppKit's Window menu brings a minimized window back explicitly.
        app.menuBars.menuBarItems["Window"].click()
        let item = app.menuBars.menuBarItems["Window"].menuItems.matching(
            NSPredicate(format: "title CONTAINS %@", "zsh")).firstMatch
        XCTAssertTrue(item.exists, "Window menu must list the staged terminal")
        item.click()
        app.typeText("printf 'ISSUE228-%s\\n' 'LIVE-RESTORED'\n")
        let restoredOutput = NSPredicate(format: "value CONTAINS %@", "ISSUE228-LIVE-RESTORED")
        expectation(for: restoredOutput, evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        let restored = window.screenshot().pngRepresentation
        XCTAssertNotEqual(after, restored, "the canvas must update after occlusion")
        let restoredShot = XCTAttachment(data: restored, uniformTypeIdentifier: "public.png")
        restoredShot.name = "issue228-after-restore"; restoredShot.lifetime = .keepAlways; add(restoredShot)
    }
}
