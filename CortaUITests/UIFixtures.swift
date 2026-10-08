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

/// The stages `stage-ui-fixtures.sh` prepares, and the app launched against
/// one. The UI-test runner is sandboxed: what it writes lands in its own
/// container, which the app cannot read, so a stage a test wrote for itself
/// was silently not the one the app loaded — it started with the user's
/// prompt and an 80×24 grid, and the test failed on what it then saw.
enum UIFixtures {
    /// The prepared stage named `name`, or a setup failure that says how to prepare
    /// it — never a test run against whatever the app finds instead.
    static func stage(_ name: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["CORTA_UI_FIXTURES"] else {
            throw NSError(
                domain: "CortaUITests.Setup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "setup failure: set TEST_RUNNER_CORTA_UI_FIXTURES using CortaUITests/stage-ui-fixtures.sh; the runner's sandbox cannot write a stage the app can read.",
                ])
        }
        let stage = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: stage.appendingPathComponent("config").path)
        else {
            throw NSError(
                domain: "CortaUITests.Setup", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "setup failure: stage-ui-fixtures.sh made no stage named \(name)",
                ])
        }
        return stage
    }

    /// The development app built beside this runner — not Launch Services'
    /// pick among the checkouts that share its bundle identifier — against
    /// `stage`, with the stage's zshrc and English.
    @MainActor static func app(stage: URL, runner: AnyClass) -> XCUIApplication {
        let products = Bundle(for: runner).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = XCUIApplication(url: products.appendingPathComponent("CortaDev.app"))
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["HOME"] = stage.path
        app.launchEnvironment["CORTA_STAGE_DIR"] = stage.path
        app.launchEnvironment["ZDOTDIR"] = stage.path
        app.launchEnvironment["SHELL"] = "/bin/zsh"
        app.launchEnvironment["CORTA_RESTORE_WINDOWS"] = "0"
        return app
    }

    /// Fails as a *setup* failure unless the pane shows the stage's prompt:
    /// a feature assertion after a missed fixture reports a feature bug
    /// that is not there.
    @MainActor static func requireFixturePrompt(
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let terminal = app.textViews.firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (terminal.value as? String)?.contains("demo ❯") == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail(
            "setup failure: the app did not load the fixture's zshrc (no `demo ❯` prompt) — check CORTA_UI_FIXTURES, not the feature",
            file: file, line: line)
    }
}
