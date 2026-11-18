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
import CortaPOSIX
import Testing
@testable import Corta

/// Waiting for you comes only from an agent (#524): a `blocked` report counts
/// only while the pane's foreground program is a built-in or configured agent.
@MainActor
@Suite(.serialized, .configurationSerialized)
struct AgentWaitGateTests {
    private final class Pane: TerminalPaneViewController {
        override func viewDidLoad() {}
    }
    /// `program` stands in for the foreground process the gate reads: the
    /// session really runs `cat`, which echoes each report back as output.
    private func pane(program: String = "claude", entryPoint: String? = nil) throws -> TerminalPaneViewController {
        let pane = Pane()
        pane.view = NSView()
        pane.session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), workingDirectory: "/")
        pane.session.start()
        pane.agents.foregroundProgram = { _ in (program, entryPoint) }
        return pane
    }
    private func send(_ payload: String, to pane: TerminalPaneViewController) async throws {
        let marker = UUID().uuidString
        pane.session.write(Array((payload + "\u{1B}]2;" + marker + "\u{1B}\\\n").utf8))
        let deadline = SuspendingClock.now + .seconds(5)
        while pane.session.windowTitle != marker, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(pane.session.windowTitle == marker)
        pane.agents.readOutput()
    }
    private func osc(_ payload: String) -> String { "\u{1B}]" + payload + "\u{1B}\\" }

    @Test func aWaitFromAProgramThatIsNotAnAgentRaisesNoAttention() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        // What `printf` at a prompt or `cat` of a file looks like to the gate.
        let shell = try pane(program: "zsh"), reader = try pane(program: "cat")
        defer {
            for pane in [shell, reader] { pane.agents.reset(); pane.session.stop() }
            ConfigurationStore.shared.update { $0 = original }
        }
        for pane in [shell, reader] {
            try await send(osc("7501;state=blocked:kind=permission:app=claude-code"), to: pane)
            #expect(pane.agents.status?.state == .unknown)
            #expect(pane.agents.status?.kind == nil)
            #expect(pane.agents.statusIsUnverified)
            #expect(!pane.taskNotifier.programBlocked, "no notice, no Dock count")
            #expect(!AgentDirectory.shared.waiting.paneIDs.contains(pane.taskNotifier.paneID), "no queue entry")
            let entry = AgentDirectory.entries(of: [pane]).first
            #expect(entry?.title.hasSuffix(L10n.text("agent.state.unknown") + " · " + L10n.text("agent.unverified"))
                == true)
        }
        // The same report from an agent is a wait.
        let agent = try pane(program: "node", entryPoint: "/opt/homebrew/bin/codex")
        defer { agent.agents.reset(); agent.session.stop() }
        try await send(osc("7501;state=blocked:kind=permission"), to: agent)
        #expect(agent.agents.status?.state == .blocked)
        #expect(!agent.agents.statusIsUnverified)
        #expect(agent.taskNotifier.programBlocked)
        #expect(AgentDirectory.shared.waiting.paneIDs.contains(agent.taskNotifier.paneID))
    }

    @Test func aWaitIsCheckedAgainForANewProgram() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        var program = "zsh"
        let pane = try pane()
        pane.agents.foregroundProgram = { _ in (program, nil) }
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=blocked:kind=question"), to: pane)
        #expect(pane.agents.statusIsUnverified)
        // A further report in the same unverified wait is not read again.
        program = "claude"
        try await send("output", to: pane)
        #expect(pane.agents.statusIsUnverified)
        // A new wait is: the agent now in front raises it.
        try await send(osc("7501;state=working") + osc("7501;state=blocked:kind=permission"), to: pane)
        #expect(pane.agents.status?.state == .blocked)
        #expect(!pane.agents.statusIsUnverified)
        #expect(AgentDirectory.shared.waiting.paneIDs.contains(pane.taskNotifier.paneID))
    }

    @Test func agentStatusOffShowsNothingAndStillQueuesNoForgedWait() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = false }
        let pane = try pane(program: "zsh")
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=blocked:kind=permission"), to: pane)
        #expect(pane.agents.status == nil)
        #expect(!pane.agents.statusIsUnverified)
        #expect(!pane.taskNotifier.programBlocked)
        #expect(!AgentDirectory.shared.waiting.paneIDs.contains(pane.taskNotifier.paneID))
    }

    @Test func agentsAreNamedByTheirExecutableOrTheScriptAnInterpreterRuns() {
        func agent(_ process: String?, _ entry: String? = nil, configured: String = "") -> Bool {
            PaneAgents.isAgent(process: process, entryPoint: entry, configured: configured)
        }
        #expect(agent("claude"))
        #expect(agent("codex"))
        #expect(agent("node", "/opt/homebrew/bin/codex"))
        #expect(agent("node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"))
        #expect(agent("my-agent", configured: "my-agent"))
        #expect(agent("python3", "/opt/tools/my-agent.py", configured: "my-agent"))
        #expect(!agent(nil))
        #expect(!agent(""))
        #expect(!agent("zsh"))
        #expect(!agent("cat"))
        #expect(!agent("ssh"), "a remote pane cannot name the program that reported")
        #expect(!agent("node", "/Users/me/projects/claude/server.js"))
        #expect(!agent("node"))
    }
}
