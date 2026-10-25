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

import Darwin
import Foundation
import Testing
@testable import CortaTerminal

/// Billable, opt-in acceptance using the installed CLI, never synthetic OSC.
/// Run only with explicit user authorization. All tool actions are read-only;
/// Bash permission is cancelled, never approved. Evidence stays local.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CORTA_REAL_MODEL_ACCEPTANCE"] == "1"))
struct RealClaudeLifecycleTests {
    private struct Fixture {
        var session: TerminalSession
        var directory: URL
    }

    private func launch(_ prompt: String, tools: String, extra: [String] = [], invalidAuth: Bool = false, crashFixture: Bool = false) throws -> Fixture {
        let inherited = ProcessInfo.processInfo.environment
        let executable = try #require(inherited["CORTA_REAL_CLAUDE"])
        let cwd = try #require(inherited["CORTA_REAL_CWD"])
        let root = URL(fileURLWithPath: inherited["CORTA_REAL_EVIDENCE"] ?? NSTemporaryDirectory())
        let directory = root.appendingPathComponent("claude-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var environment = ChildEnvironment.default()
        environment["HOME"] = inherited["CORTA_REAL_HOME"]
        environment["TERM_PROGRAM"] = "Corta"
        environment["TERM"] = "xterm-256color"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["CLAUDE_CODE_MAX_RETRIES"] = "0"
        for key in ["TMUX", "STY", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE", "CLAUDE_CODE_SESSION_KIND"] {
            environment[key] = nil
        }
        if invalidAuth {
            // An intentionally invalid per-process credential must never
            // cause account recovery or writes in the user's config store.
            environment["HOME"] = directory.path
            environment["CLAUDE_CONFIG_DIR"] = directory.path
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
                environment[key] = nil
            }
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = "corta-intentionally-invalid-acceptance-token"
            let config: [String: Any] = ["hasCompletedOnboarding": true, "theme": "dark",
                "projects": [cwd: ["hasTrustDialogAccepted": true]]]
            try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent(".claude.json"))
        }
        let settings = #"{"disableAllHooks":true,"preferredNotifChannel":"notifications_disabled","permissions":{"ask":["Bash"]}}"#
        var command = [executable, "--no-chrome", "--strict-mcp-config", "--tools", tools,
            "--permission-mode", "manual", "--effort", "low", "--settings", settings,
            "--debug-file", directory.appendingPathComponent("debug.log").path] + extra + [prompt]
        if crashFixture {
            environment["CORTA_LIVE_PID_FILE"] = directory.appendingPathComponent("pid").path
            // A disposable integrated shell owns this exact child and emits
            // its actual wait status. SIGKILL prevents the CLI sending clear.
            let shell = #"printf '\033]133;A\007\033]133;C\007'; "$@" <&0 & worker=$!; printf '%s' "$worker" > "$CORTA_LIVE_PID_FILE"; wait "$worker"; result=$?; printf '\033]133;D;%d\007\033]133;A\007' "$result"; exec /bin/cat"#
            command = ["/bin/sh", "-c", shell, "corta-compatibility-fixture"] + command
        }
        let args = ["-q", "-F", directory.appendingPathComponent("transcript").path] + command
        let session = try TerminalSession(executable: "/usr/bin/script", arguments: args,
            environment: environment, workingDirectory: cwd)
        session.start()
        print("Real Claude lifecycle evidence: \(directory.path)")
        return Fixture(session: session, directory: directory)
    }

    private func wait(_ seconds: Int = 90, until condition: () -> Bool) -> Bool {
        let deadline = SuspendingClock.now + .seconds(seconds)
        while SuspendingClock.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test func permissionCancellationReportsIdleInsteadOfDone() throws {
        let fixture = try launch("Run exactly /bin/sleep 30 using Bash. Do not run any other tool.", tools: "Bash")
        defer { fixture.session.stop() }
        #expect(wait { fixture.session.programStatuses[""]?.kind == .permission })
        #expect(fixture.session.programStatuses[""]?.state == .blocked)
        fixture.session.write([0x1B]) // Esc cancels this invocation, no approval.
        #expect(wait(20) { fixture.session.programStatuses[""]?.state == .idle })
        #expect(fixture.session.programStatuses[""]?.state != .done)
    }

    @Test func invalidModelReportsErrorInsteadOfDone() throws {
        let fixture = try launch("Reply only OK.", tools: "", extra: ["--model", "claude-corta-invalid-model"])
        defer { fixture.session.stop() }
        #expect(wait { fixture.session.programStatuses[""]?.state == .error })
        #expect(fixture.session.programStatuses[""]?.kind == nil)
    }

    @Test func invalidIsolatedCredentialReportsAuthenticationWait() throws {
        let fixture = try launch("Reply only OK.", tools: "", invalidAuth: true)
        defer { fixture.session.stop() }
        #expect(wait { fixture.session.programStatuses[""]?.kind == .auth })
        #expect(fixture.session.programStatuses[""]?.state == .blocked)
    }

    @Test func abruptCLIExitReturnsToIntegratedShellWithoutStaleWaiting() throws {
        let fixture = try launch("Run exactly /bin/sleep 30 using Bash. Do not run other tools.",
            tools: "Bash", crashFixture: true)
        defer { fixture.session.stop() }
        try #require(wait { fixture.session.programStatuses[""]?.kind == .permission })
        let text = try String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try #require(Int32(text))
        #expect(kill(pid, SIGKILL) == 0) // only the fixture's unreaped child
        #expect(wait(20) { !fixture.session.isCommandRunning && fixture.session.programStatuses[""]?.state == .error })
        #expect(fixture.session.programStatuses.count == 1)
        #expect(fixture.session.programStatuses[""]?.kind == nil)
        #expect(fixture.session.programProgress == nil)
        #expect(fixture.session.ioFailure == nil)
    }

    @Test func realSubtaskIsIdentifiedAndClearedBeforeMainCompletion() throws {
        let agents = #"{"compatibility-worker":{"description":"A worker used only for terminal status acceptance","prompt":"Reply only OK. Do not use tools.","tools":[],"model":"haiku"}}"#
        let fixture = try launch("Use Agent exactly once with subagent_type compatibility-worker to ask it to reply OK. Wait for it, then reply only OK. Do not use other tools.",
            tools: "Agent", extra: ["--agents", agents])
        defer { fixture.session.stop() }
        var childIDs = Set<String>()
        #expect(wait(120) {
            childIDs.formUnion(fixture.session.programStatuses.keys.filter { !$0.isEmpty })
            return fixture.session.programStatuses[""]?.state == .done
        })
        #expect(!childIDs.isEmpty)
        #expect(fixture.session.programStatuses.keys.allSatisfy { $0.isEmpty })
        let transcript = try String(contentsOf: fixture.directory.appendingPathComponent("transcript"), encoding: .utf8)
        for id in childIDs { #expect(transcript.contains("7501;state=clear:id=" + id)) }
    }
}
