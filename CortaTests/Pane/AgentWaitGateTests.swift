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

/// Waiting for you comes only from an agent (#524): a `blocked` report counts
/// only while the pane's foreground program is a built-in or configured agent.
@MainActor
@Suite(.serialized, .configurationSerialized)
struct AgentWaitGateTests {
    private final class Pane: TerminalPaneViewController {
        override func viewDidLoad() {}
    }
    private static func program(_ members: (String, String?)...) -> ForegroundProgram {
        ForegroundProgram(members: members.map { .init(name: $0.0, entryPoint: $0.1) })
    }
    /// `program` stands in for the foreground group the session stamps on
    /// a wait: the session really runs `cat`, which echoes each report back.
    private func pane(_ program: ForegroundProgram) throws -> TerminalPaneViewController {
        let pane = Pane()
        pane.view = NSView()
        pane.session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), workingDirectory: "/")
        pane.session.start()
        pane.agents.reporter = { _ in program }
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
        // What `printf` at a prompt, `cat` of a file and a remote host look like.
        let panes = try [Self.program(("zsh", nil)), Self.program(("cat", nil)), Self.program(("ssh", nil))]
            .map { try pane($0) }
        defer {
            for pane in panes { pane.agents.reset(); pane.session.stop() }
            ConfigurationStore.shared.update { $0 = original }
        }
        for pane in panes {
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
        // The same report from an agent behind a wrapper is a wait.
        let agent = try pane(Self.program(("caffeinate", nil), ("claude", nil)))
        defer { agent.agents.reset(); agent.session.stop() }
        try await send(osc("7501;state=blocked:kind=permission"), to: agent)
        #expect(agent.agents.status?.state == .blocked)
        #expect(!agent.agents.statusIsUnverified)
        #expect(agent.taskNotifier.programBlocked)
        #expect(AgentDirectory.shared.waiting.paneIDs.contains(agent.taskNotifier.paneID))
    }

    @Test func eachWaitIsJudgedByWhoBeganIt() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        let pane = try pane(Self.program(("claude", nil)))
        // `cat evil.txt; claude`: the forged record was stamped with `cat`.
        pane.agents.reporter = { $0.app == "evil" ? Self.program(("cat", nil)) : Self.program(("claude", nil)) }
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=blocked:kind=permission:id=x:app=evil"), to: pane)
        try await send(osc("7501;state=blocked:kind=question:app=claude-code"), to: pane)
        #expect(AgentDirectory.shared.waiting.paneIDs.contains(pane.taskNotifier.paneID))
        #expect(pane.agents.status?.kind == .question, "the agent's own wait, not the forged one")
        // The agent moves on; the forged record left behind raises nothing.
        try await send(osc("7501;state=working:app=claude-code"), to: pane)
        #expect(!AgentDirectory.shared.waiting.paneIDs.contains(pane.taskNotifier.paneID))
        #expect(!pane.taskNotifier.programBlocked)
        #expect(pane.agents.status?.state == .working)
    }

    @Test func anUnverifiedWaitCannotHoldAnAgentsPlaceInTheQueue() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        let first = try pane(Self.program(("claude", nil))), second = try pane(Self.program(("claude", nil)))
        first.agents.reporter = { $0.app == "evil" ? Self.program(("cat", nil)) : Self.program(("claude", nil)) }
        let firstID = first.taskNotifier.paneID, secondID = second.taskNotifier.paneID
        defer {
            for pane in [first, second] { pane.agents.reset(); pane.session.stop() }
            ConfigurationStore.shared.update { $0 = original }
        }
        func ours() -> [UUID] { AgentDirectory.shared.waiting.paneIDs.filter { [firstID, secondID].contains($0) } }
        try await send(osc("7501;state=blocked:kind=question"), to: first)
        try await send(osc("7501;state=blocked:id=x:app=evil"), to: first)
        try await send(osc("7501;state=blocked:kind=question"), to: second)
        #expect(ours() == [firstID, secondID])
        // The agent leaves waiting and comes back between two reads. The
        // forged record still waiting must not make that the same wait.
        try await send(osc("7501;state=working") + osc("7501;state=blocked:kind=permission"), to: first)
        #expect(ours() == [secondID, firstID])
    }

    @Test func agentStatusOffShowsNothingAndStillQueuesNoForgedWait() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = false }
        let pane = try pane(Self.program(("zsh", nil)))
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

    @Test func agentsAreNamedByAnExecutableOrAnInstalledCommand() {
        func agent(_ members: (String, String?)..., configured: String = "") -> Bool {
            PaneAgents.isAgent(ForegroundProgram(members: members.map { .init(name: $0.0, entryPoint: $0.1) }),
                configured: configured)
        }
        #expect(agent(("claude", nil)))
        #expect(agent(("codex-aarch64-apple-darwin", nil)))
        #expect(agent(("gemini-cli", nil)))
        #expect(agent(("node", "/opt/homebrew/bin/codex")))
        #expect(agent(("node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js")))
        #expect(agent(("op", nil), ("claude", nil)), "an agent behind a wrapper")
        #expect(agent(("node", "/Users/me/.npm/_npx/1/node_modules/.bin/claude")))
        #expect(agent(("my-agent", nil), configured: "my-agent"))
        #expect(agent(("python3", "/opt/tools/bin/my-agent"), configured: "my-agent"))
        #expect(!agent(("python3", "/tmp/my-agent"), configured: "my-agent"), "a script, not an installed command")
        #expect(!agent(("node", "bin/claude")), "a relative path is a project's own")
        #expect(!PaneAgents.isAgent(nil, configured: ""))
        #expect(!agent(("zsh", nil)))
        #expect(!agent(("cat", nil)))
        #expect(!agent(("ssh", nil)), "a remote pane cannot name the program that reported")
        #expect(!agent(("node", "/Users/me/projects/claude/server.js")))
        #expect(!agent(("node", "scripts/claude.js")))
        #expect(!agent(("node", "scripts/claude")), "a script named after an agent is not one")
        #expect(!agent(("python3", "gemini")), "nor is a module")
        #expect(!agent(("node", nil)))
    }
}
