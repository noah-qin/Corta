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

/// The launched-app check for Space (D14): a scratch stage whose
/// `space.json` names two projects, driven by clicks, hovers and the
/// keyboard, with screenshots attached.
final class CortaSpaceUITests: XCTestCase {
    private var stage: URL!

    /// The shell script prepares public fixtures outside the runner's sandbox.
    /// Use current split-tree records, not the removed visible/dividers fields.
    @MainActor
    private func makeStage(name: String = #function) throws -> XCUIApplication {
        let fixture = "space-grid-" + name.replacingOccurrences(of: "()", with: "")
        stage = try UIFixtures.stage(fixture)
        return UIFixtures.app(stage: stage, runner: Self.self)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForFrame(_ frame: CGRect, of window: XCUIElement) {
        let restored = NSPredicate { _, _ in window.frame == frame }
        let restoration = XCTNSPredicateExpectation(predicate: restored, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restoration], timeout: 3), .completed,
                       "the terminal gets its own frame back after the mode animation")
    }

    @MainActor
    private func panels(_ app: XCUIApplication) -> XCUIElementQuery {
        app.groups.matching(identifier: "Corta.Space.Panel")
    }

    @MainActor
    func testSpaceGridSidebarAndModes() throws {
        continueAfterFailure = false
        let app = try makeStage()
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous); app.terminate() }
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.typeText("printf 'terminal mode\\n'\n")
        let echoed = NSPredicate { _, _ in
            (app.textViews.firstMatch.value as? String)?.contains("terminal mode") == true
        }
        let echo = XCTNSPredicateExpectation(predicate: echoed, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [echo], timeout: 3), .completed)
        let frame = window.frame

        // Into Space by the toolbar's one mode button: the saved grid, and
        // the window takes the screen.
        let showSpace = app.toolbars.buttons["Show Space"]
        XCTAssertTrue(showSpace.waitForExistence(timeout: 5))
        showSpace.click()
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(panels(app).count, 3)
        XCTAssertGreaterThan(window.frame.width, frame.width)
        attach(app, "Space-light-three-panels")

        // Choosing a hidden session changes nothing; ⌘Return shows it, in
        // the least recently used panel's place (the limit is 3), with a
        // note that offers Undo.
        let sidebar = app.outlines["Corta.Space.Sidebar"]
        let before = panels(app).allElementsBoundByIndex.map(\.label)
        sidebar.staticTexts["Terminal 5"].click()
        XCTAssertEqual(panels(app).allElementsBoundByIndex.map(\.label), before, "choosing is not showing")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertEqual(panels(app).count, 3)
        // NSGlassEffectView does not expose its container as an AX Other.
        // Its real Undo control must be visible, and the following action restores the grid.
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 2))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(panels(app).allElementsBoundByIndex.map(\.label), before, "undone")

        // The panel's menu: on hover, and on the header's context menu.
        let panel = panels(app).element(boundBy: 0)
        panel.hover()
        XCTAssertTrue(panel.buttons["Panel Actions"].waitForExistence(timeout: 2))
        panel.staticTexts.firstMatch.rightClick()
        XCTAssertTrue(app.menuItems["Hide Panel"].waitForExistence(timeout: 2))
        app.menuItems["Hide Panel"].click()
        XCTAssertEqual(panels(app).count, 2)
        attach(app, "Space-after-hide")

        // Renaming a session from its row.
        sidebar.staticTexts["Terminal 2"].doubleClick()
        app.typeText("Agent B\r")
        XCTAssertTrue(sidebar.staticTexts["Agent B"].waitForExistence(timeout: 3))

        // Another project; then back to the terminal mode, untouched.
        sidebar.staticTexts["api-server"].click()
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(panels(app).count, 1)
        app.toolbars.buttons["Show Terminal"].click()
        XCTAssertEqual(panels(app).count, 0)
        waitForFrame(frame, of: window)
        let terminal = app.textViews.firstMatch
        XCTAssertTrue((terminal.value as? String)?.contains("terminal mode") == true)
    }

    @MainActor
    func testFullScreenAndSidebarToggle() throws {
        let app = try makeStage()
        defer { app.terminate() }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        let sidebar = app.outlines["Corta.Space.Sidebar"]
        let toggle = app.toolbars.buttons["Show Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.click()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 3))
        toggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
        app.typeKey("f", modifierFlags: [.command, .control])
        sleep(2)
        attach(app, "Space-full-screen")
        app.typeKey("f", modifierFlags: [.command, .control])
        sleep(2)
    }

    @MainActor
    func testSSHRetentionIsOnlyOfferedInSpaceAndDefaultsOn() throws {
        let fixture = try UIFixtures.stage("space-ssh")
        let app = UIFixtures.app(stage: fixture, runner: Self.self)
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.toolbars.buttons["Connect…"].click()
        let retention = app.switches["connect-retain-ssh"]
        XCTAssertFalse(retention.exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        app.toolbars.buttons["Connect…"].click()
        XCTAssertTrue(retention.waitForExistence(timeout: 3))
        XCTAssertEqual((retention.value as? NSNumber)?.intValue, 1)
        retention.click()
        XCTAssertEqual((retention.value as? NSNumber)?.intValue, 0)
        attach(app, "Space-SSH-retention-off")
        app.typeKey(.escape, modifierFlags: [])
        app.toolbars.buttons["Connect…"].click()
        XCTAssertEqual((retention.value as? NSNumber)?.intValue, 1)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testProjectFilesCannotConfigureSpace() throws {
        guard let library = ProcessInfo.processInfo.environment["CORTA_FILE_AUDIT_LIBRARY"] else {
            throw XCTSkip("Provide a task-only open/openat/fopen interposer for the filesystem acceptance trace")
        }
        let fixture = try UIFixtures.stage("space-trust")
        let app = UIFixtures.app(stage: fixture, runner: Self.self)
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = library
        app.launchEnvironment["CORTA_FILE_AUDIT_ROOT"] = fixture.path
        let trace = fixture.appendingPathComponent("opened-files.log")
        app.launchEnvironment["CORTA_FILE_AUDIT_LOG"] = trace.path
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.toolbars.buttons["Show Space"].click()
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        let log = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("ready\n"), "the tracing fixture must actually load")
        XCTAssertTrue(log.contains(fixture.appendingPathComponent("config").path), "positive open control")
        for name in ["space.json", ".corta", "sessions"] {
            XCTAssertFalse(log.contains(fixture.appendingPathComponent("project/" + name).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("should-not-exist").path))
        let attachment = XCTAttachment(string: log)
        attachment.name = "Space app project-file open trace"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDarkSpaceScreenshot() throws {
        let app = try makeStage()
        defer { app.terminate() }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        // View ▸ Show Space by its key, which the other test leaves untried.
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(panels(app).firstMatch.waitForExistence(timeout: 5))
        attach(app, "Space-dark-three-panels")
    }
}
