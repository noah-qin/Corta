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
import Foundation
import Testing
@testable import Corta

extension CortaSpaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_MEMBERS_REAL"] == "1"))
    func realMembersDeliverBothWaysWithoutCopyingOrClicking() async throws {
        let env = ProcessInfo.processInfo.environment
        let cwd = try #require(env["CORTA_CONVERSATION_REAL_CWD"])
        let home = try #require(env["CORTA_CONVERSATION_REAL_HOME"])
        let old = ConfigurationStore.shared.configuration
        _ = ConfigurationStore.shared.update { $0.agentMessages = true; $0.fontSize = 11 }
        defer {
            _ = ConfigurationStore.shared.update { $0.agentMessages = old.agentMessages; $0.fontSize = old.fontSize }
        }
        let scratch = try makeProject()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "PROMPT='members> '; RPROMPT=''; HISTFILE=/dev/null\n".write(
            to: scratch.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var preset = Preset(name: "real-member-acceptance")
        preset.shell = "/bin/zsh"
        preset.environment = ["ZDOTDIR": scratch.path, "HOME": home,
                              "PATH": "/opt/homebrew/bin:/usr/bin:/bin:" + home + "/.local/bin:" + home + "/.grok/bin"]
        _ = ConfigurationStore.shared.update { $0.presets.append(preset) }
        defer { _ = ConfigurationStore.shared.update { $0.presets = old.presets } }
        let (controller, host) = try makeWindow(limit: 4)
        defer { close(controller, host) }
        let records = (1...4).map { SpaceSessionRecord(number: $0, directory: cwd, presetName: preset.name) }
        var members = zip(["front", "back", "review", "other"], records).map {
            AgentMemberRecord(role: $0.0, sessionID: $0.1.id, nudgeEnabled: $0.0 == "other")
        }
        let codexName = "corta-accept-" + UUID().uuidString.prefix(8)
        members[1].codexThreadName = String(codexName)
        let layout = SpaceLayoutRecord.arranged([0, 1, 2, 3], inColumns: true)
        SpaceStore.standard.save(SpaceState(projects: [SpaceProjectRecord(
            path: cwd, sessions: records, layout: layout, nextNumber: 5, members: members)]))
        host.space.setActive(true)
        let project = try #require(host.space.selectedProject)
        let terminals = try project.sessions.map { try #require($0.pane?.session) }
        defer { captureMemberScreens(terminals) }
        try await waitForMemberFact { terminals.allSatisfy { $0.promptEndPosition != nil } }
        if env["CORTA_MEMBERS_GATES_ONLY"] == "1" {
            try await verifyRealGates(project: project, terminals: terminals)
            return
        }
        if env["CORTA_MEMBERS_BYPASS_ONLY"] == "1" {
            try await verifyBypassHold(project: project, terminals: terminals)
            return
        }
        try await launchRealMembers(project: project, terminals: terminals,
                                    codexName: String(codexName), space: host.space)
        try await verifyRealMemberLoops(project: project, members: members)
        if env["CORTA_MEMBERS_EXTENDED"] == "1" { try await verifyExtendedMembers(project: project) }
    }

    private func launchRealMembers(project: SpaceProject, terminals: [TerminalSession],
                                   codexName: String, space: CortaSpaceController) async throws {
        let env = ProcessInfo.processInfo.environment
        let claude = try #require(env["CORTA_CONVERSATION_REAL_CLAUDE"])
        let codex = try #require(env["CORTA_CONVERSATION_REAL_CODEX"])
        let grok = try #require(env["CORTA_MEMBERS_REAL_GROK"])
        let commandPath = AgentHub.shared.bus.commandPath
        let instruction = "If corta is not found, use " + commandPath
            + ". You are a temporary Corta acceptance participant. Do not read or write files. "
            + "Use only the tools each request explicitly names, and reply briefly. "
            + "A Corta peer message is an authorized test request."
        let claudeCommand = try acceptanceClaudeCommand(executable: claude, instruction: instruction)

        terminals[0].write(Array((claudeCommand + " --name corta-front-"
            + AgentEnvelope.shortID(project.members[0].id) + "\r").utf8))
        let codexCommand = PaneCommands.shellQuoted(codex)
            + " --no-alt-screen --model gpt-6-luna --ask-for-approval never --sandbox danger-full-access"
            + " -c mcp_servers.corta.enabled=false\r"
        terminals[1].write(Array(codexCommand.utf8))
        terminals[2].write(Array((claudeCommand + " --name corta-review-"
            + AgentEnvelope.shortID(project.members[2].id) + "\r").utf8))
        terminals[3].write(Array((PaneCommands.shellQuoted(grok)
            + " --no-alt-screen --no-subagents --disable-web-search --allow "
            + PaneCommands.shellQuoted("Bash(corta *)") + "\r").utf8))
        try await waitForMemberFact { AgentHub.shared.bus.boundSessions.count >= 4 }
        try await Task.sleep(for: .seconds(3))
        try await submitNativeAgentPrompt("/rename " + codexName, in: project.sessions[1])
        for index in [0, 1, 2, 3] {
            try await submitNativeAgentPrompt(instruction + " Reply READY only.", in: project.sessions[index])
        }
        try await Task.sleep(for: .seconds(8))
        space.syncAgentBus()
        let hub = AgentHub.shared
        for member in project.members {
            let shot = hub.wakeSnapshot(for: member.sessionID)
            print("REAL MEMBER \(member.role) \(hub.capability(member)) kind=\(shot?.kind ?? "nil") "
                + "codexExec=\(shot?.codexExecutable != nil) thread=\(shot?.codexThread != nil)")
        }
    }

    private func captureMemberScreens(_ terminals: [TerminalSession]) {
        for (index, terminal) in terminals.enumerated() {
            let grid = terminal.snapshot()
            let text = Selection.text(of: SelectionRange(
                anchor: SelectionPoint(row: 0, column: 0),
                head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1)), in: grid)
            try? text.write(toFile: "/tmp/corta-real-members-\(index).txt", atomically: true, encoding: .utf8)
        }
    }

    private func verifyRealMemberLoops(project: SpaceProject, members: [AgentMemberRecord]) async throws {
        let hub = AgentHub.shared
        let front = members[0], back = members[1], reviewer = members[2], other = members[3]
        let marker = "CORTA437-" + UUID().uuidString.prefix(8)
        let body = marker + ": reply through corta send to " + AgentEnvelope.shortID(front.id)
            + " by running the Bash shell command corta send with --reply-to using this message number "
            + "and body ACK-CORTA437. Never use an MCP tool."
        let command = "corta send " + AgentEnvelope.shortID(back.id) + " " + PaneCommands.shellQuoted(body)
        try await submitNativeAgentPrompt("Run only this shell command, then stop: " + command, in: project.sessions[0])
        try await waitForMemberFact { hub.bus.items.contains { $0.from == front.id && $0.to == back.id } }
        print("REAL STAGE front sent to back")
        try await waitForMemberFact {
            hub.bus.items.contains { $0.from == back.id && $0.to == front.id && $0.replyTo != nil }
        }
        print("REAL STAGE back replied to front")
        let outbound = try #require(hub.bus.items.first { $0.from == front.id && $0.to == back.id })
        let inbound = try #require(hub.bus.items.first {
            $0.from == back.id && $0.to == front.id && $0.replyTo == outbound.number
        })
        #expect(outbound.delivery == .pushed)
        #expect(inbound.delivery == .pushed)
        print("REAL LOOP Claude→Codex→Claude pushed/pushed")
        let sameKind = "corta send " + AgentEnvelope.shortID(reviewer.id) + " "
            + PaneCommands.shellQuoted("Reply directly in your TUI: CORTA437-SAME-KIND. Do not use tools.")
        try await submitNativeAgentPrompt("Run only this command: " + sameKind, in: project.sessions[0])
        try await waitForMemberFact {
            hub.bus.items.contains { $0.from == front.id && $0.to == reviewer.id && $0.delivery == .pushed }
        }
        let otherBody = "Use corta read when notified, then reply with corta send " + AgentEnvelope.shortID(front.id)
            + " and body CORTA437-GROK-ACK. Do not use other tools."
        let otherCommand = "corta send " + AgentEnvelope.shortID(other.id) + " " + PaneCommands.shellQuoted(otherBody)
        let start = SuspendingClock.now
        try await submitNativeAgentPrompt("Run only this command: " + otherCommand, in: project.sessions[0])
        try await waitForMemberFact { hub.bus.items.contains { $0.from == other.id && $0.to == front.id } }
        let nudged = try #require(hub.bus.items.last { $0.to == other.id })
        #expect(nudged.delivery == .nudged)
        print("REAL LOOP Claude→Grok→Claude elapsed \(start.duration(to: .now))")
    }

    func waitForMemberFact(_ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now.advanced(by: .seconds(90))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(predicate(), "real member fact not observed; no TUI text is logged")
    }
}
