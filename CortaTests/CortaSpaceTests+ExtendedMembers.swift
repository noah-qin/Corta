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
    func acceptanceClaudeCommand(executable: String, instruction: String) throws -> String {
        let path = AgentHub.shared.bus.commandPath
        let config: [String: Any] = ["mcpServers": ["cortaAcceptance": ["command": path, "args": ["mcp"]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let base = PaneCommands.shellQuoted(executable) + " --effort low --allowedTools "
            + PaneCommands.shellQuoted("Bash(corta *) Bash(" + path + " *) mcp__cortaAcceptance__*")
            + " --append-system-prompt " + PaneCommands.shellQuoted(instruction)
        guard ProcessInfo.processInfo.environment["CORTA_MEMBERS_EXTENDED"] == "1" else { return base }
        return base + " --mcp-config " + PaneCommands.shellQuoted(json) + " --strict-mcp-config"
    }

    func verifyExtendedMembers(project: SpaceProject) async throws {
        try await verifyNativeSendMessage(project)
        try await verifyMCPOnlyLoop(project)
        try await verifyGrokAsFrontEnd(project, waiting: true)
        try await verifyGrokAsFrontEnd(project, waiting: false)
    }

    func verifyBypassHold(project: SpaceProject, terminals: [TerminalSession]) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORTA_CONVERSATION_REAL_CLAUDE"])
        let command = PaneCommands.shellQuoted(executable) + " --effort low"
        terminals[0].write(Array((command + "\r").utf8))
        let overlay = PaneCommands.shellQuoted("{\"skipDangerousModePermissionPrompt\":true}")
        terminals[2].write(Array((command + " --dangerously-skip-permissions --settings " + overlay + "\r").utf8))
        let hub = AgentHub.shared
        let front = project.members[0], target = project.members[2]
        try await waitForMemberFact { hub.capability(front) == "push" && hub.capability(target) == "push" }
        try await Task.sleep(for: .seconds(2))
        let marker = "CORTA437-BYPASS-HOLD"
        let sent = hub.exchange(AgentRequest(operation: "send", to: target.id.uuidString,
            body: marker + ". This is a transport acceptance probe; do not use tools."), caller: front.id)
        let number = try #require(sent.number)
        let task = try #require(hub.deliveryTasks[number])
        #expect(await task.value == .pushed)
        try await waitForMemberFact {
            let text = visibleText(project.sessions[2]).lowercased()
            return text.contains(marker.lowercased())
                && (text.contains("approve") || text.contains("deny") || text.contains("allow this"))
        }
        #expect(hub.bus.status(number: number)?.read == false)
        print("REAL bypass Claude showed inbound approval; pushed stayed unread")
    }

    private func verifyNativeSendMessage(_ project: SpaceProject) async throws {
        let name = "corta-review-" + AgentEnvelope.shortID(project.members[2].id)
        let marker = "CORTA437-NATIVE-" + UUID().uuidString.prefix(8)
        let prompt = "Use only native SendMessage (not MCP or Bash) to send to " + name
            + " this exact message: Reply directly in your own conversation with " + marker + ". Do not use tools."
        try await submitNativeAgentPrompt(prompt, in: project.sessions[0])
        try await waitForMemberFact { visibleText(project.sessions[2]).contains(marker) }
        #expect(!visibleText(project.sessions[1]).contains(marker))
        print("REAL native Claude SendMessage reached the named same-directory peer")
    }

    private func verifyMCPOnlyLoop(_ project: SpaceProject) async throws {
        let hub = AgentHub.shared
        let front = project.members[0], review = project.members[2]
        let marker = "CORTA437-MCP-" + UUID().uuidString.prefix(8)
        let body = "Use only the cortaAcceptance MCP corta_send tool to reply to " + AgentEnvelope.shortID(front.id)
            + " with reply_to this message number and body " + marker + ". No Bash or native SendMessage."
        let prompt = "Use only the cortaAcceptance MCP corta_send tool to send to " + AgentEnvelope.shortID(review.id)
            + " with body: " + body
        try await submitNativeAgentPrompt(prompt, in: project.sessions[0])
        try await waitForMemberFact {
            hub.bus.items.contains { $0.from == review.id && $0.to == front.id && $0.body.contains(marker) }
        }
        let response = try #require(hub.bus.items.last { $0.from == review.id && $0.body.contains(marker) })
        #expect(response.replyTo != nil)
        #expect(response.delivery == .pushed)
        print("REAL MCP-only Claude→Claude→Claude loop")
    }

    private func verifyGrokAsFrontEnd(_ project: SpaceProject, waiting: Bool) async throws {
        let hub = AgentHub.shared
        let front = project.members[0], other = project.members[3]
        let marker = "CORTA437-GROK-FRONT-" + UUID().uuidString.prefix(8)
        let body = "Run only a corta shell send reply to " + AgentEnvelope.shortID(other.id)
            + " with body " + marker + ". Do not use MCP or native SendMessage."
        let path = hub.bus.commandPath
        let command = path + " send " + AgentEnvelope.shortID(front.id) + " " + PaneCommands.shellQuoted(body)
            + (waiting ? " && " + path + " wait --timeout 30" : "")
        try await submitNativeAgentPrompt("Run only this shell command, then stop: " + command,
                                         in: project.sessions[3])
        try await waitForMemberFact {
            hub.bus.items.contains { $0.from == front.id && $0.to == other.id && $0.body.contains(marker) && $0.read }
        }
        let reply = try #require(hub.bus.items.last { $0.to == other.id && $0.body.contains(marker) })
        if waiting {
            #expect(Date().timeIntervalSinceReferenceDate - reply.at < 1)
            print("REAL Grok frontend wait received reply within one second of bus arrival")
        } else {
            #expect(reply.delivery == .nudged)
            print("REAL Grok frontend idle reply resumed through nudge/read")
        }
    }
}
