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

    /// A stage with two project folders, and a Space file that shows three of
    /// the first project's five sessions.
    private func makeStage(appearance: String) throws -> XCUIApplication {
        stage = FileManager.default.temporaryDirectory.appendingPathComponent("CortaSpaceUI-" + UUID().uuidString)
        let projects = stage.appendingPathComponent("projects")
        let web = projects.appendingPathComponent("web-app"), api = projects.appendingPathComponent("api-server")
        for folder in [web.appendingPathComponent("src"), api] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let support = stage.appendingPathComponent("ApplicationSupport")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = "appearance = \(appearance)\nrestore-windows = false\ncolumns = 180\nrows = 50\n"
            + "space-panel-limit = 3\n"
        try config.write(to: stage.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "PROMPT='%1~ ❯ '\nRPROMPT=''\n".write(
            to: stage.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let sessions = (1...5).map { #"{"number":\#($0),"directory":"\#(web.path)"}"# }.joined(separator: ",")
        let json = """
            {"version":1,"selectedProject":"\(web.path)","projects":[
             {"path":"\(web.path)","sessions":[\(sessions)],"visible":[0,1,2],"dividers":[],"nextNumber":6},
             {"path":"\(api.path)","sessions":[{"number":1,"directory":"\(api.path)"}],"visible":[0],"dividers":[],"nextNumber":2}
            ]}
            """
        try json.write(to: support.appendingPathComponent("space.json"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["ZDOTDIR"] = stage.path
        return app
    }

    override func tearDown() {
        if let stage { try? FileManager.default.removeItem(at: stage) }
        super.tearDown()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func panels(_ app: XCUIApplication) -> XCUIElementQuery {
        app.groups.matching(identifier: "Corta.Space.Panel")
    }

    @MainActor
    func testSpaceGridSidebarAndModes() throws {
        continueAfterFailure = false
        let app = try makeStage(appearance: "light")
        let previous = LatinInputSource.select()
        defer { LatinInputSource.restore(previous); app.terminate() }
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let frame = window.frame
        app.typeText("printf 'terminal mode\\n'\n")

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
        XCTAssertTrue(app.otherElements["Corta.Space.Note"].waitForExistence(timeout: 2))
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
        XCTAssertEqual(window.frame, frame, "the terminal gets its own frame back")
        let terminal = app.textViews.firstMatch
        XCTAssertTrue((terminal.value as? String)?.contains("terminal mode") == true)
    }

    @MainActor
    func testFullScreenAndSidebarToggle() throws {
        let app = try makeStage(appearance: "light")
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
    func testDarkSpaceScreenshot() throws {
        let app = try makeStage(appearance: "dark")
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
