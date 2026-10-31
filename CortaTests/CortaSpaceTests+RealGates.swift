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
import Darwin
import Foundation
import Testing
@testable import Corta

extension CortaSpaceTests {
    func verifyRealGates(project: SpaceProject, terminals: [TerminalSession]) async throws {
        let env = ProcessInfo.processInfo.environment
        let claude = try #require(env["CORTA_CONVERSATION_REAL_CLAUDE"])
        let grok = try #require(env["CORTA_MEMBERS_REAL_GROK"])
        let hub = AgentHub.shared
        let front = project.members[0], other = project.members[3]
        terminals[0].write(Array((PaneCommands.shellQuoted(claude) + " --effort low\r").utf8))
        terminals[3].write(Array((PaneCommands.shellQuoted(grok)
            + " --no-alt-screen --no-subagents --disable-web-search --allow "
            + PaneCommands.shellQuoted("Bash(corta *)") + "\r").utf8))
        try await waitForMemberFact {
            hub.capability(front) == "push" && hub.bus.boundSessions.contains(other.sessionID)
        }
        let group = try #require(terminals[3].pty.foregroundProcessGroup)
        try await submitNativeAgentPrompt("Temporary acceptance only: do not read or write files. "
            + "If corta is not found use " + hub.bus.commandPath + ". Reply READY only.", in: project.sessions[3])
        try await Task.sleep(for: .seconds(6))
        try await submitNativeAgentPrompt("Run only the Bash shell command sleep 8, then answer DONE. No other tools.",
                                         in: project.sessions[3])
        try await waitForMemberFact { hasSleepDescendant(group) }
        try await Task.sleep(for: .seconds(1))
        let prompt = "Run corta read, then corta send " + AgentEnvelope.shortID(front.id)
            + " with body CORTA-GATE-ACK-DO-NOT-REPLY. No other tools."
        let queued = hub.exchange(AgentRequest(operation: "send", to: other.id.uuidString, body: prompt),
                                  caller: front.id)
        #expect(queued.delivery == "queued")
        #expect(!visibleText(project.sessions[3]).contains(AgentEnvelope.nudgeText))
        try await waitForMemberFact { hub.bus.items.contains { $0.from == other.id && $0.to == front.id } }
        print("REAL busy Grok received no nudge during sleep, then resumed automatically")
        try await verifyRealDraftAndOffGate(project)
        try await verifyShellDoesNotReceiveANudge(project)
    }

    private func verifyRealDraftAndOffGate(_ project: SpaceProject) async throws {
        let hub = AgentHub.shared
        let front = project.members[0], other = project.members[3]
        let pane = try #require(project.sessions[3].pane)
        project.members[3].nudgeEnabled = false
        CortaSpaceController.owner?.syncAgentBus()
        let off = hub.exchange(AgentRequest(operation: "send", to: other.id.uuidString, body: "gate-off"),
                               caller: front.id)
        #expect(off.delivery == "queued")
        _ = hub.bus.read(member: other.id)
        project.members[3].nudgeEnabled = true
        CortaSpaceController.owner?.syncAgentBus()
        let before = visibleText(project.sessions[3]).components(separatedBy: AgentEnvelope.nudgeText).count
        pane.terminalView.insertText("CORTA-USER-DRAFT", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .seconds(4))
        let draft = hub.exchange(AgentRequest(operation: "send", to: other.id.uuidString, body: "gate-draft"),
                                 caller: front.id)
        #expect(draft.delivery == "queued")
        try await Task.sleep(for: .seconds(3))
        #expect(visibleText(project.sessions[3]).contains("CORTA-USER-DRAFT"))
        #expect(visibleText(project.sessions[3]).components(separatedBy: AgentEnvelope.nudgeText).count == before)
        #expect(pane.terminalView.hasUnsubmittedInput)
        _ = hub.bus.read(member: other.id)
        print("REAL Grok draft survived the quiet interval; wake-up off stayed queued")
    }

    private func verifyShellDoesNotReceiveANudge(_ project: SpaceProject) async throws {
        let hub = AgentHub.shared
        let terminal = try #require(project.sessions[3].pane?.session)
        let group = try #require(terminal.pty.foregroundProcessGroup)
        try #require(group > 1 && group != terminal.pty.processIdentifier)
        #expect(kill(-group, SIGTERM) == 0)
        try await waitForMemberFact { terminal.pty.foregroundProcessGroup == terminal.pty.processIdentifier }
        let before = visibleText(project.sessions[3]).components(separatedBy: AgentEnvelope.nudgeText).count
        let reply = hub.exchange(AgentRequest(operation: "send", to: project.members[3].id.uuidString,
            body: "CORTA-NO-SHELL-WAKE"), caller: project.members[0].id)
        #expect(reply.delivery == "queued" || reply.delivery == "refused(unbound)")
        try await Task.sleep(for: .seconds(1))
        #expect(visibleText(project.sessions[3]).components(separatedBy: AgentEnvelope.nudgeText).count == before)
        print("REAL foreground shell received no reminder after the agent exited")
    }

    private func hasSleepDescendant(_ root: pid_t) -> Bool {
        var pending = [root], seen = Set<pid_t>()
        while let pid = pending.popLast(), seen.count < 128 {
            guard seen.insert(pid).inserted else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if URL(fileURLWithPath: path).lastPathComponent == "sleep" { return true }
            }
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
            if count > 0 { pending += children.prefix(min(Int(count), children.count)).filter { $0 > 0 } }
        }
        return false
    }
}
