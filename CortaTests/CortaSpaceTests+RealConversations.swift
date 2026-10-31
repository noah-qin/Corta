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
import CortaTerminal
import Testing
@testable import Corta

extension CortaSpaceTests {
    /// Opt-in: installed authenticated CLIs, one tiny model request each, no tool calls requested.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_CONVERSATION_REAL_CWD"] != nil))
    func realClaudeAndNpmCodexSourcesSurviveClosingAndReopeningSpace() async throws {
        let environment = ProcessInfo.processInfo.environment
        let cwd = try #require(environment["CORTA_CONVERSATION_REAL_CWD"])
        let claude = try #require(environment["CORTA_CONVERSATION_REAL_CLAUDE"])
        let codex = try #require(environment["CORTA_CONVERSATION_REAL_CODEX"])
        let realHome = try #require(environment["CORTA_CONVERSATION_REAL_HOME"])
        let scratch = try makeProject()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "PROMPT='acceptance> '; RPROMPT=''; HISTFILE=/dev/null\n".write(
            to: scratch.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var preset = Preset(name: "real-conversation-acceptance")
        preset.shell = "/bin/zsh"
        preset.environment = ["ZDOTDIR": scratch.path, "HOME": realHome,
                              "PATH": "/opt/homebrew/bin:/usr/bin:/bin:" + realHome + "/.local/bin"]
        let oldPresets = ConfigurationStore.shared.configuration.presets
        _ = ConfigurationStore.shared.update { $0.presets.append(preset) }
        defer { _ = ConfigurationStore.shared.update { $0.presets = oldPresets } }
        let (controller, host) = try makeWindow(limit: 2)
        defer { close(controller, host) }
        let records = (1...2).map { SpaceSessionRecord(number: $0, directory: cwd, presetName: preset.name) }
        SpaceStore.standard.save(SpaceState(projects: [SpaceProjectRecord(
            path: cwd, sessions: records,
            layout: .split(vertical: true, fraction: 0.5, first: .panel(0), second: .panel(1)), nextNumber: 3)]))
        host.space.setActive(true)
        let project = try #require(host.space.selectedProject)
        let terminals = try project.sessions.map { try #require($0.pane?.session) }
        try await waitForRealConversation { terminals.allSatisfy { $0.promptEndPosition != nil } }
        terminals[0].write(Array((PaneCommands.shellQuoted(claude) + "\r").utf8))
        terminals[1].write(Array((PaneCommands.shellQuoted(codex) + " --no-alt-screen --model gpt-6-luna\r").utf8))
        try await waitForRealConversation {
            project.sessions[0].record.conversation?.kind == .claude
                && project.sessions[1].record.conversation?.kind == .codex
        }
        // Explicit test input, unrelated to Corta's unsubmitted restoration text.
        try await Task.sleep(for: .seconds(3))
        for item in project.sessions {
            try await submitNativeAgentPrompt("Reply with CORTA-436-READY only. Do not use tools.", in: item)
        }
        try await waitForRealConversation {
            project.sessions.allSatisfy { visibleText($0).components(separatedBy: "CORTA-436-READY").count >= 3 }
        }
        await host.space.sampleConversations()
        _ = try await realConversationEvidence(in: host.space, project: project, terminals: terminals)
        let saved = try await verifyRealClear(host: host, project: project, terminals: terminals)
        host.teardown()
        controller.window?.close()
        try await verifyRealConversationRestore(saved)
    }

    private func verifyRealClear(host: SplitViewController, project: SpaceProject,
                                 terminals: [TerminalSession]) async throws -> SpaceState {
        let original = try #require(project.sessions[0].record.conversation?.id)
        let identity = try #require(project.sessions[0].conversationObservation?.processes.first)
        try await submitNativeAgentPrompt("/clear", in: project.sessions[0])
        try await Task.sleep(for: .seconds(2))
        try await submitNativeAgentPrompt("Reply with CORTA-436-CLEARED only. Do not use tools.",
            in: project.sessions[0])
        try await waitForRealConversation {
            guard let current = project.sessions[0].record.conversation?.id else { return false }
            return current != original
        }
        try await waitForRealConversation {
            visibleText(project.sessions[0]).components(separatedBy: "CORTA-436-CLEARED").count >= 3
        }
        #expect(project.sessions[0].conversationObservation?.processes.first == identity,
                "/clear changes the conversation within the same kernel process identity")
        return try await realConversationEvidence(in: host.space, project: project, terminals: terminals)
    }

    private func verifyRealConversationRestore(_ saved: SpaceState) async throws {
        SpaceStore.standard.save(saved)
        let reopened = TerminalWindowController(setup: .init())
        let reopenedHost = try #require(reopened.contentViewController as? SplitViewController)
        defer { close(reopened, reopenedHost) }
        reopened.showWindow(nil)
        reopenedHost.space.setActive(true)
        let restored = try #require(reopenedHost.space.selectedProject)
        try await waitForRealConversation {
            restored.sessions.allSatisfy { item in
                guard let terminal = item.pane?.session, let command = item.record.conversation?.command else {
                    return false
                }
                let grid = terminal.snapshot()
                let text = Selection.text(of: SelectionRange(
                    anchor: SelectionPoint(row: 0, column: 0),
                    head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1)), in: grid)
                return text.contains(command) && !terminal.isCommandRunning
            }
        }
    }

    private func realConversationEvidence(
        in space: CortaSpaceController, project: SpaceProject, terminals: [TerminalSession]
    ) async throws -> SpaceState {
        let observations = try project.sessions.map { try #require($0.conversationObservation) }
        for observation in observations {
            print("REAL conversation kind=\(observation.conversation.kind.rawValue) "
                  + "source=\(observation.conversation.source.rawValue) "
                  + "result=\(observation.reason?.rawValue ?? "success")")
        }
        #expect(observations[0].conversation.source == .sessionRecord,
                "picker is not a passing Claude enhancement check")
        let agent = try #require(observations[0].processes.first)
        let record = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/" + String(agent.pid) + ".json")
        struct Identity: Decodable { let sessionId: UUID }
        let identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: record))
        #expect(identity.sessionId == observations[0].conversation.id)
        let elapsed = await Task.detached(priority: .utility) {
            let start = SuspendingClock.now
            _ = terminals.map { $0.conversationObservation }
            return start.duration(to: .now)
        }.value
        print("REAL all-agent round (2 panes, warm cache, utility task): \(elapsed)")
        space.saveNow()
        let saved = SpaceStore.standard.load()
        #expect(saved.projects[0].sessions.map(\.conversation) == project.sessions.map { $0.record.conversation })
        return saved
    }

    private func waitForRealConversation(_ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now + .seconds(20 * Double(testTimeoutScale))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(predicate())
    }
}
