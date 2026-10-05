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

/// Search and tabs, against the live app: ⌘F opens the search bar and Esc
/// closes it; ⌘T adds a native tab (a second window in the tab group).
final class SearchAndTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandFOpensTheSearchBarAndEscapeClosesIt() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)
        let searchField = window.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "⌘F must show the search bar")

        // A query that cannot match: the bar reports it rather than hanging.
        searchField.typeText("zzz-no-such-string")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(
            searchField.waitForExistence(timeout: 2), "Esc must dismiss the search bar")
    }

    @MainActor
    func testCommandTOpensATab() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)

        // A native tab group exposes its tabs as radio buttons; the window
        // count stays 1 because the new session is a tab, not a window.
        // A native tab group exposes its tabs as `.tab`-type children whose
        // accessible label reports the count ("Tab bar, 2 tabs.").
        let tabGroup = window.tabGroups.firstMatch
        XCTAssertTrue(tabGroup.waitForExistence(timeout: 5), "⌘T must open a tab bar")
        let twoTabs = NSPredicate(format: "label CONTAINS '2 tabs'")
        expectation(for: twoTabs, evaluatedWith: tabGroup)
        waitForExpectations(timeout: 5)
    }

    /// A ⌘T must not take a chrome height off the shared window frame —
    /// four tabs would collapse a 451pt window to the 49pt minimum. The
    /// risk is real because inserting `.fullSizeContentView` re-derives the
    /// frame from the content size, and a tab, unlike a standalone window,
    /// never overwrites the frame afterwards.
    ///
    /// The tab bar appearing does grow the frame once, by its own height, so
    /// that the panes keep their row count; after that the frame is fixed.
    @MainActor
    func testTabsDoNotShrinkTheWindow() throws {
        let app = XCUIApplication()
        // Session restore would otherwise carry the previous
        // test's windows into this one; the suite asserts window counts.
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let beforeAnyTab = window.frame

        app.typeKey("t", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let withTabBar = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            withTabBar.height, beforeAnyTab.height,
            "the tab bar must not eat into the window's height")

        for tab in 2...4 {
            app.typeKey("t", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let frame = app.windows.firstMatch.frame
            XCTAssertEqual(
                frame.height, withTabBar.height, accuracy: 1,
                "tab \(tab) resized the window: \(frame) vs \(withTabBar)")
            XCTAssertEqual(
                frame.width, withTabBar.width, accuracy: 1,
                "tab \(tab) resized the window: \(frame) vs \(withTabBar)")
        }
    }
    /// Reproduces #213 with isolated configuration and deterministic output.
    /// Screenshots cover the titlebar, which offscreen Metal tests cannot see.
    @MainActor
    func testFeedbackAppearanceTabsAndFontSize() throws {
        let previousInput = LatinInputSource.select()
        // XCTest teardown also runs when a fail-fast assertion aborts the
        // test before Swift's normal scope cleanup.
        addTeardownBlock { LatinInputSource.restore(previousInput) }
        defer { LatinInputSource.restore(previousInput) }
        guard let externalStage = ProcessInfo.processInfo.environment["CORTA_FEEDBACK_STAGE"] else {
            throw XCTSkip("Set TEST_RUNNER_CORTA_FEEDBACK_STAGE using stage-feedback-ui.sh; the app cannot use another app's sandbox container.")
        }
        let stage = URL(fileURLWithPath: externalStage)
        let shell = stage.appendingPathComponent("fixture.sh")
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = XCUIApplication(url: products.appendingPathComponent("CortaDev.app"))
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        app.launchEnvironment["SHELL"] = shell.path
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.buttons["Secure Keyboard Entry is enabled. Click to open Privacy & Security settings."].exists)
        let original = app.windows.firstMatch.frame
        app.typeKey("=", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // In place: the top edge stays and the size moves by less than a
        // cell (`SplitViewController.fitWindowToWholeCells`).
        let zoomed = app.windows.firstMatch.frame
        XCTAssertEqual(zoomed.minY, original.minY, accuracy: 0.5)
        XCTAssertEqual(zoomed.minX, original.minX, accuracy: 0.5)
        XCTAssertLessThan(abs(zoomed.width - original.width), 20)
        XCTAssertLessThan(abs(zoomed.height - original.height), 20)
        XCTAssertFalse(app.windows.firstMatch.label.contains("×"))
        app.typeKey("0", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.tabGroups.firstMatch.waitForExistence(timeout: 5))
        let file = app.menuBars.firstMatch.menuBarItems["File"]
        file.click()
        file.menuItems["Rename Tab…"].click()
        let title = app.textFields.matching(identifier: "tab-title-editor").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let editingTab = app.windows.firstMatch.tabGroups.firstMatch.descendants(matching: .tab)
            .allElementsBoundByIndex.first { $0.isSelected }
        if let editingTab {
            XCTAssertEqual(title.frame.midX, editingTab.frame.midX, accuracy: 4)
        }
        let renameShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        renameShot.name = "feedback-inline-rename"
        renameShot.lifetime = .keepAlways
        add(renameShot)
        title.typeText("TableFixture")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.windows["TableFixture"].waitForExistence(timeout: 3))
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.windows["TableFixture"].exists)
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows["TableFixture"].exists)
        let namedTab = app.windows.firstMatch.tabGroups.firstMatch.descendants(matching: .tab)
            .matching(identifier: "TableFixture").firstMatch
        XCTAssertTrue(namedTab.exists)
        namedTab.doubleClick()
        XCTAssertTrue(app.textFields["tab-title-editor"].waitForExistence(timeout: 3))
        app.textFields["tab-title-editor"].typeText("CanceledName")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.windows["TableFixture"].exists)
        namedTab.rightClick()
        let newTab = try XCTUnwrap(app.menuItems.matching(identifier: "New Tab")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        newTab.click()
        XCTAssertTrue(app.windows.firstMatch.tabGroups.firstMatch.label.contains("3 tabs"))
        app.typeKey("[", modifierFlags: [.command, .shift])
        for mode in ["Dark", "Light", "Dark", "Light"] {
            let view = app.menuBars.firstMatch.menuBarItems["View"]
            view.click()
            view.menuItems["Theme"].hover()
            view.menuItems[mode].click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
            XCTAssertTrue(config.contains("appearance = \(mode.lowercased())"), "Appearance must persist in the isolated config")
            let shot = app.windows.firstMatch.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "feedback-tabs-\(mode)"
            attachment.lifetime = .keepAlways
            add(attachment)
            // The source window image retains alpha. A transparent titlebar
            // must not survive any light/dark transition.
            let image = try XCTUnwrap(shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = CGColorSpaceCreateDeviceRGB()
            let ctx = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: image.width*3/5, y: 20, width: 1, height: 1)))
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertEqual(pixel[3], 255, "Titlebar must remain opaque in \(mode)")
            if mode == "Light" { XCTAssertGreaterThan(pixel[0], 120, "Light titlebar must not expose a black desktop") }
            else { XCTAssertLessThan(pixel[0], 120, "Dark appearance must actually apply") }
        }
        app.typeKey(",", modifierFlags: .command)
        let keyboardSettings = app.windows["Corta.Settings"]
        XCTAssertTrue(keyboardSettings.waitForExistence(timeout: 5))
        keyboardSettings.outlines.firstMatch.staticTexts["Keyboard & Mouse"].click()
        let indicatorMode = keyboardSettings.popUpButtons["input-source-indicator-mode"]
        indicatorMode.click()
        indicatorMode.menuItems["Always in focused pane"].click()
        keyboardSettings.buttons[XCUIIdentifierCloseWindow].click()
        let badge = app.staticTexts["input-source-indicator"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let badgeShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        badgeShot.name = "feedback-input-source"
        badgeShot.lifetime = .keepAlways
        add(badgeShot)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Corta.Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.outlines.firstMatch.staticTexts["Appearance"].click()
        let theme = settings.popUpButtons["appearance-theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 3))
        theme.click()
        XCTAssertTrue(theme.menuItems["Corta"].exists)
        XCTAssertTrue(theme.menuItems["Mono"].exists)
        theme.menuItems["Solarized"].click()
        let config = try String(contentsOf: stage.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(config.contains("theme = solarized"))
        let preview = settings.descendants(matching: .any).matching(identifier: "appearance-preview").firstMatch
        XCTAssertEqual(preview.value as? String, "light")
        let settingsShot = XCTAttachment(screenshot: settings.screenshot())
        settingsShot.name = "feedback-settings"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)
        settings.buttons[XCUIIdentifierCloseWindow].click()

    }

}
