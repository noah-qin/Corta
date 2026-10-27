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
    @MainActor func testClearScreenKeepsPromptAndEditingCursor() throws {
        continueAfterFailure = false
        let original = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(original) }
        let stage = try UIFixtures.stage("terminal-recovery")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        let terminal = app.textViews.firstMatch
        func expectText(_ text: String) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: terminal)
            waitForExpectations(timeout: 5)
        }
        app.typeText("printf 'old-output\\n'\n")
        expectText("old-output\ndemo ❯")
        app.typeKey("k", modifierFlags: .command)
        expectText("demo ❯")
        XCTAssertFalse((terminal.value as? String)?.contains("old-output") == true)
        app.typeText("printf '%s\\n' abcd")
        expectText("demo ❯ printf '%s\\n' abcd")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        expectText("demo ❯ printf '%s\\n' abcd")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "clear-screen-unsubmitted-input"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeText("X")
        expectText("demo ❯ printf '%s\\n' abXcd")
        app.typeKey(.return, modifierFlags: [])
        expectText("abXcd\ndemo ❯")
    }

    @MainActor func testAboutAndHistoryCenterOverInvokingWindow() throws {
        continueAfterFailure = false
        let stage = try UIFixtures.stage("terminal-recovery")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        defer { app.terminate() }
        let parent = app.windows.firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        let parentFrame = parent.frame
        func assertCentered(_ window: XCUIElement) {
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            print("Window placement: parent=\(parentFrame), child=\(window.frame)")
            expectation(for: NSPredicate { _, _ in
                abs(window.frame.midX - parentFrame.midX) <= 2 &&
                abs(window.frame.midY - parentFrame.midY) <= 2
            }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = window.title
            shot.lifetime = .keepAlways
            add(shot)
        }
        let appMenu = app.menuBars.firstMatch.menuBarItems.element(boundBy: 1)
        appMenu.click()
        appMenu.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "About")).firstMatch.click()
        let about = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "About")).firstMatch
        assertCentered(about)
        about.buttons[XCUIIdentifierCloseWindow].click()
        app.menuBars.menuBarItems["Shell"].click()
        app.menuBars.menuBarItems["Shell"].menuItems["Search Command History…"].click()
        assertCentered(app.windows["Command History"])
    }

    @MainActor func testClearScreenLeavesVimAlternateScreenIntact() throws {
        continueAfterFailure = false
        let original = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(original) }
        let stage = try UIFixtures.stage("terminal-recovery")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        UIFixtures.requireFixturePrompt(in: app)
        let terminal = app.textViews.firstMatch
        app.typeText("/usr/bin/vim -Nu NONE -n -i NONE -c 'call setline(1, \"vim-clear-proof\")'\n")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "vim-clear-proof"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        let before = terminal.value as? String
        app.typeKey("k", modifierFlags: .command)
        XCTAssertEqual(terminal.value as? String, before)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "clear-screen-vim-intact"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeText(":q!\n")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "demo ❯"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
    }

    @MainActor func testResetThenSynchronizedOutputRecoversItsCanvas() throws {
        continueAfterFailure = false
        let original = LatinInputSource.select()
        addTeardownBlock { LatinInputSource.restore(original) }
        let stage = try UIFixtures.stage("terminal-recovery").path
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
        XCTAssertNotEqual(
            canvasPixels(held), canvasPixels(stillHeld),
            "timeout must release the hold so later input changes the canvas")
        let heldShot = XCTAttachment(data: stillHeld, uniformTypeIdentifier: "public.png")
        heldShot.name = "issue228-sync-recovered"; heldShot.lifetime = .keepAlways; add(heldShot)
        app.typeText("printf 'ISSUE228-%s\\n' 'NEXT-FRAME'\n")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "ISSUE228-NEXT-FRAME"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        let released = terminal.screenshot().pngRepresentation
        XCTAssertNotEqual(
            canvasPixels(stillHeld), canvasPixels(released), "the next command must also update the recovered canvas")
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
        let stage = try UIFixtures.stage("terminal-recovery").path
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
