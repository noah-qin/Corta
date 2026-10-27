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

final class AgentStatusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Opt-in, billable acceptance against an installed, authenticated Claude.
    /// Only a disposable marker may be written; no persistent tool approval.
    @MainActor
    func testRealClaudeBackgroundPermissionAndNotificationChannels() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let claude = environment["CORTA_REAL_CLAUDE"],
              let home = environment["CORTA_REAL_HOME"] else {
            throw XCTSkip(
                "Set TEST_RUNNER_CORTA_REAL_CLAUDE and TEST_RUNNER_CORTA_REAL_HOME for real Claude acceptance")
        }
        let stage = try UIFixtures.stage("real-claude")
        let supported = ["auto", "iterm2", "ghostty", "kitty"]
        let channels = environment["CORTA_REAL_CHANNELS"]?.split(separator: ",").map(String.init) ?? supported
        guard !channels.isEmpty, channels.allSatisfy({ supported.contains($0) }) else {
            throw NSError(domain: "CortaUITests.Setup", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CORTA_REAL_CHANNELS must contain auto,iterm2,ghostty or kitty"])
        }
        for channel in channels {
            let marker = UUID().uuidString
            let transcriptURL = stage.appendingPathComponent(marker).appendingPathComponent("transcript")
            let prefix = Self.wirePrefix(for: channel)
            let app = launchRealClaude(channel: channel, marker: marker, stage: stage, claude: claude, home: home)
            defer { app.terminate() }
            // Digits avoid the editor's ordinary spelling substitutions.
            let targetTitle = "409" + String(Int.random(in: 100_000_000...999_999_999))
            renameTab(in: app, to: targetTitle)
            app.typeKey("t", modifierFlags: .command)

            // Claude delays its explicit attention notice. Observe the real
            // wire event before clicking, rather than racing that delay.
            if let prefix { Self.waitForWireEvent(prefix, in: transcriptURL) }

            // Notification permission, if not yet granted for this isolated
            // bundle, must be approved by the human, never by this test.
            let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
            let message = center.descendants(matching: .group).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", targetTitle, targetTitle)).firstMatch
            Self.reveal(message, in: center, waiting: 5)
            XCTAssertTrue(
                message.waitForExistence(timeout: 100),
                "Real Claude \(channel) must post a background permission notice")
            let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
            let icon = dock.descendants(matching: .any).matching(NSPredicate(
                format: "title == %@", environment["CORTA_REAL_APP_NAME"] ?? "CortaDev")).firstMatch
            XCTAssertTrue(icon.waitForExistence(timeout: 5))
            print("Real Claude \(channel) Dock icon: \(icon.debugDescription)")
            // Dock does not expose badge text through AX on every macOS.
            // Retain the actual system tile for visual acceptance as well.
            keep(icon.screenshot(), named: "real-claude-\(channel)-dock-waiting")
            print("Real Claude \(channel) notice: \(message.debugDescription)")
            approvePermission(from: message, in: app, channel: channel)
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                stage.appendingPathComponent(marker).appendingPathComponent("approved").path))
            Self.checkTranscript(
                String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self), prefix: prefix, channel: channel)
            keep(icon.screenshot(), named: "real-claude-\(channel)-dock-completed")
            if let prefix {
                try checkIdleReminder(
                    in: app, center: center, channel: channel, prefix: prefix, transcriptURL: transcriptURL)
            }
            app.terminate()
        }
    }

    /// Exercises real Notification Center and the real click delegate, with
    /// public fixture text. Permission is never changed by the test.
    @MainActor
    func testProgramNotificationChannelsAndClick() throws {
        guard ProcessInfo.processInfo.environment["CORTA_UI_NOTIFICATIONS"] == "1" else {
            throw XCTSkip(
                "Set TEST_RUNNER_CORTA_UI_NOTIFICATIONS=1 for real Notification Center "
                    + "acceptance; notification permission is not changed by this test"
            )
        }
        let stage = try UIFixtures.stage("agent-notifications")
        for channel in ["iterm2", "ghostty", "kitty"] {
            let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
            app.launchEnvironment["SHELL"] = stage.appendingPathComponent("notice-shell").path
            app.launchEnvironment["TEST_AGENT_MARKER"] = UUID().uuidString
            app.launchEnvironment["TEST_AGENT_CHANNEL"] = channel
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            app.typeKey("t", modifierFlags: .command)
            let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
            let message = center.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Corta 409 \(channel)", "Corta 409 \(channel)")).firstMatch
            if !message.waitForExistence(timeout: 5) {
                // Focus modes may suppress banners while keeping the
                // notification in Notification Center. Open its clock area
                // without changing the user's Focus or permission settings.
                let menuBar = center.menuBars.firstMatch
                XCTAssertTrue(menuBar.waitForExistence(timeout: 3))
                menuBar.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            }
            guard message.waitForExistence(timeout: 8) else {
                let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                shot.name = "notification-\(channel)-not-delivered"; shot.lifetime = .keepAlways; add(shot)
                XCTFail("No \(channel) banner observed; notification permission or OS delivery may require attention")
                return
            }
            message.click()
            expectation(for: NSPredicate(format: "value CONTAINS %@", "Notification target \(channel)"),
                        evaluatedWith: app.textViews.firstMatch)
            waitForExpectations(timeout: 5)
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "notification-\(channel)-click-focused-pane"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    @MainActor
    func testBackgroundStatusAndAgentsJump() throws {
        let stage = try UIFixtures.stage("agents")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("auto-shell").path
        app.launchEnvironment["TEST_AGENT_MARKER"] = UUID().uuidString
        app.launchEnvironment["TEST_AGENT_MODE"] = "signal"
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 5)
        // Status must arrive while the first tab's render loop is paused.
        app.menuBars.menuBarItems["Window"].click()
        let agents = app.menuBars.menuItems["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3))
        agents.hover()
        let waiting = app.menuBars.menuItems.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@", "Waiting for you", "Review changes")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "agent-background-waiting-menu-and-tab"; shot.lifetime = .keepAlways; add(shot)
        waiting.click()
        let terminal = app.textViews.firstMatch
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "Background permission fixture"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
        // Palette lists agent panes and can jump with the same row identity.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Review changes")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        app.typeKey("c", modifierFlags: .control)
    }

    @MainActor
    func testClaudeDoneWhileProcessRemainsAlive() throws {
        let stage = try UIFixtures.stage("agents")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("auto-shell").path
        app.launchEnvironment["TEST_AGENT_MARKER"] = UUID().uuidString
        app.launchEnvironment["TEST_AGENT_MODE"] = "completion"
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        let rows = app.descendants(matching: .any)
        let working = rows.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Working")).firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 3))
        let done = rows.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.click()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Ready for another turn"),
                    evaluatedWith: app.textViews.firstMatch)
        waitForExpectations(timeout: 3)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "claude-done-process-alive"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testFallbackProcessIsUnknownUntilSessionEnds() throws {
        let stage = try UIFixtures.stage("agents")
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("auto-shell").path
        app.launchEnvironment["TEST_AGENT_MARKER"] = UUID().uuidString
        app.launchEnvironment["TEST_AGENT_MODE"] = "fallback"
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        let unknown = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "State unknown")).firstMatch
        XCTAssertTrue(unknown.waitForExistence(timeout: 3))
        // Leave the palette open across process exit: rows update from events.
        let idle = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Idle")).firstMatch
        XCTAssertTrue(idle.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "agent-fallback-session-ended-palette"; shot.lifetime = .keepAlways; add(shot)
        app.typeKey(.escape, modifierFlags: [])
    }
}

// MARK: - Real Claude acceptance steps

extension AgentStatusUITests {
    /// The escape sequence a channel's explicit notification starts with;
    /// nil for `auto`, which sends none.
    private static func wirePrefix(for channel: String) -> String? {
        switch channel {
        case "iterm2": "\u{1B}]9;"
        case "ghostty": "\u{1B}]777;notify;"
        case "kitty": "\u{1B}]99;"
        default: nil
        }
    }

    /// Corta started with a shell that runs the real Claude for `channel`,
    /// its first pane focused.
    @MainActor
    private func launchRealClaude(
        channel: String, marker: String, stage: URL, claude: String, home: String
    ) -> XCUIApplication {
        let app = UIFixtures.app(stage: stage, runner: Self.self, usingTestTarget: true)
        app.launchEnvironment["HOME"] = home
        app.launchEnvironment["SHELL"] = stage.appendingPathComponent("claude-shell").path
        app.launchEnvironment["TEST_CLAUDE"] = claude
        app.launchEnvironment["TEST_CLAUDE_CWD"] = ProcessInfo.processInfo.environment["CORTA_REAL_CWD"]
        app.launchEnvironment["TEST_AGENT_CHANNEL"] = channel
        app.launchEnvironment["TEST_AGENT_MARKER"] = marker
        app.launchEnvironment["NO_COLOR"] = nil
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        let initialTerminal = app.textViews.firstMatch
        XCTAssertTrue(initialTerminal.waitForExistence(timeout: 10))
        initialTerminal.click()
        return app
    }

    /// Names the current tab through File > Rename Tab….
    @MainActor
    private func renameTab(in app: XCUIApplication, to title: String) {
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Rename Tab…"].click()
        let titleEditor = app.textFields["tab-title-editor"]
        if !titleEditor.waitForExistence(timeout: 5) {
            // On repeated relaunch AppKit can expose the window before
            // its native tab's selected accessibility frame is ready.
            app.typeKey(.escape, modifierFlags: [])
            app.textViews.firstMatch.click()
            app.menuBars.menuBarItems["File"].click()
            app.menuBars.menuItems["Rename Tab…"].click()
        }
        XCTAssertTrue(titleEditor.waitForExistence(timeout: 10))
        titleEditor.typeKey("a", modifierFlags: .command)
        titleEditor.typeText(title)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Up to a minute for `prefix` to appear in the CLI's transcript.
    private static func waitForWireEvent(_ prefix: String, in transcriptURL: URL) {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let data = (try? Data(contentsOf: transcriptURL)) ?? Data()
            if String(decoding: data, as: UTF8.self).contains(prefix) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Opens Notification Center from the menu bar clock when `notice`
    /// is not on screen within `timeout`.
    @MainActor
    private static func reveal(_ notice: XCUIElement, in center: XCUIApplication, waiting timeout: TimeInterval) {
        guard !notice.waitForExistence(timeout: timeout) || !notice.isHittable else { return }
        let menuBar = center.menuBars.firstMatch
        if menuBar.exists {
            menuBar.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        }
    }

    @MainActor
    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Clicking the notice lands on Claude's permission question, which
    /// its first option approves for this invocation only; then the
    /// command palette lists the agents, where it is done and is picked.
    @MainActor
    private func approvePermission(from message: XCUIElement, in app: XCUIApplication, channel: String) {
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let terminal = app.textViews.firstMatch
        let landing = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS %@", "Do you want to proceed?"), object: terminal)
        if XCTWaiter.wait(for: [landing], timeout: 1) != .completed, message.exists {
            // macOS first expands a collapsed stack; its individual
            // notification is actionable only after that expansion.
            message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "Do you want to proceed?"), evaluatedWith: terminal)
        waitForExpectations(timeout: 10)
        keep(app.windows.firstMatch.screenshot(), named: "real-claude-\(channel)-notification-click-permission")
        app.typeKey(.return, modifierFlags: [])
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Command Palette…"].click()
        let done = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-row-", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "Real Claude must report completion while staying alive")
        done.click()
    }

    /// The 7501 status went blocked then done; an explicit channel was
    /// used exactly when one was asked for; no progress or tab metadata.
    private static func checkTranscript(_ transcript: String, prefix: String?, channel: String) {
        XCTAssertTrue(transcript.contains("7501;state=blocked:app=claude-code:kind=permission"))
        XCTAssertTrue(transcript.contains("7501;state=done:app=claude-code"))
        if let prefix {
            XCTAssertTrue(transcript.contains(prefix), "The real CLI must emit its explicit \(channel) channel")
        } else {
            for code in ["9;", "777;notify;", "99;"] {
                XCTAssertFalse(
                    transcript.contains("\u{1B}]" + code), "auto must not select a message channel for Corta")
            }
        }
        XCTAssertFalse(
            transcript.contains("\u{1B}]9;4;"), "Normal Corta identity is not selected for native progress")
        XCTAssertFalse(transcript.contains("\u{1B}]21337;"), "Reference Claude leaves tab metadata disabled")
    }

    /// Fixed 7501 permission attention cannot prove that an explicit OSC
    /// channel delivers the CLI's own message text: waits for a separate
    /// idle reminder after blocked has ended, and clicks it.
    @MainActor
    private func checkIdleReminder(
        in app: XCUIApplication, center: XCUIApplication, channel: String, prefix: String, transcriptURL: URL
    ) throws {
        app.typeKey("t", modifierFlags: .command)
        let idleText = "Claude is waiting for your input" // 2.1.310 sender
        let idleMessage = center.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", idleText, idleText)).firstMatch
        Self.reveal(idleMessage, in: center, waiting: 70)
        XCTAssertTrue(idleMessage.waitForExistence(timeout: 60),
            "The real \(channel) channel must deliver its own idle text, not fixed permission attention")
        let idleTranscript = String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self)
        let shape: String = switch channel {
        case "iterm2": prefix + idleText
        case "ghostty": prefix + "Claude Code;" + idleText
        default: ";" + idleText
        }
        XCTAssertTrue(idleTranscript.contains(shape), "Reference sender's idle message must be present")
        keep(center.screenshot(), named: "real-claude-\(channel)-explicit-idle-text")
        idleMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground
        }, object: app)
        if XCTWaiter.wait(for: [foreground], timeout: 1) != .completed, idleMessage.exists {
            idleMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 10), .completed,
            "Click must activate Corta, not merely find background terminal text")
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "OK"), evaluatedWith: app.textViews.firstMatch)
        waitForExpectations(timeout: 10)
    }
}
