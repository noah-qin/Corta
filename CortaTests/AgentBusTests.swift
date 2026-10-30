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

import Foundation
import Testing
@testable import Corta

struct AgentBusTests {
    private let front = UUID(uuidString: "3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912")!
    private let back = UUID(uuidString: "019eee77-052d-7530-af09-17a140e08123")!

    private func makeBus() -> AgentBus {
        var bus = AgentBus()
        bus.replaceMembers([
            AgentMemberRecord(id: front, role: "frontend", sessionID: UUID()),
            AgentMemberRecord(id: back, role: "backend", sessionID: UUID(), nudgeEnabled: true),
        ])
        bus.boundSessions = Set(bus.members.map(\.sessionID))
        return bus
    }

    @Test func sendReadLimitsAndUserIsNotARecipient() {
        var bus = makeBus()
        let sent = bus.send(from: front, to: AgentEnvelope.shortID(back), body: "check the route",
                            replyTo: nil, context: [], now: 0)
        #expect(sent.1 == .queued)
        #expect(bus.read(member: back).map(\.body) == ["check the route"])
        #expect(bus.read(member: back).isEmpty)
        let role = bus.send(from: front, to: "backend", body: "no", replyTo: nil, context: [], now: 1)
        #expect(role.1 == .refused("useAnID"))
        let user = bus.send(from: front, to: "user", body: "no", replyTo: nil, context: [], now: 1)
        #expect(user.1 == .refused("userIsNotARecipient"))
        let outsider = bus.send(from: UUID(), to: AgentEnvelope.shortID(back), body: "no",
                                replyTo: nil, context: [], now: 1)
        #expect(outsider.1 == .refused("notAMember"))
        bus.boundSessions = []
        #expect(bus.send(from: front, to: AgentEnvelope.shortID(back), body: "x", replyTo: nil,
                         context: [], now: 2).1 == .refused("unbound"))
    }

    @Test func rateInboxDepthAndEmptyWaits() {
        var bus = makeBus()
        for index in 0..<AgentBus.sendsPerMinute {
            #expect(bus.send(from: front, to: AgentEnvelope.shortID(back), body: "\(index)",
                             replyTo: nil, context: [], now: 10).1 == .queued)
        }
        #expect(bus.send(from: front, to: AgentEnvelope.shortID(back), body: "more",
                         replyTo: nil, context: [], now: 10).1 == .refused("rate"))
        _ = bus.read(member: back)
        for index in 0..<AgentBus.inboxLimit {
            _ = bus.send(from: front, to: AgentEnvelope.shortID(back), body: "q", replyTo: nil,
                         context: [], now: 80 + Double(index) * 60)
        }
        #expect(bus.send(from: front, to: AgentEnvelope.shortID(back), body: "q", replyTo: nil,
                         context: [], now: 80 + Double(AgentBus.inboxLimit) * 60).1 == .refused("inboxFull"))
        var chain = makeBus()
        var previous: Int?
        for index in 0..<AgentBus.replyDepth {
            let sent = chain.send(from: front, to: AgentEnvelope.shortID(back), body: "r",
                                  replyTo: previous, context: [], now: 200 + Double(index) * 60)
            previous = sent.0
            #expect(sent.1 == .queued)
        }
        #expect(chain.send(from: front, to: AgentEnvelope.shortID(back), body: "r", replyTo: previous,
                           context: [], now: 200 + Double(AgentBus.replyDepth) * 60).1 == .refused("tooDeep"))
        for _ in 0..<AgentBus.emptyWaitLimit - 1 { #expect(chain.noteEmptyWait(member: back) == nil) }
        #expect(chain.noteEmptyWait(member: back) == .giveUp)
    }

    @Test func nudgeBytesIgnoreTheMessageAndEachGateRefuses() {
        let constant = AgentEnvelope.nudgeBytes()
        let open = AgentNudgeGate(enabled: true, foregroundIsAgent: true, idle: true, userIdle: true,
                                  composing: false, bracketedPaste: false, nudgesThisMinute: 0)
        #expect(AgentNudgeGate.bytes(gate: open, body: "secret body", role: "backend") == constant)
        #expect(!String(decoding: constant, as: UTF8.self).contains("secret"))
        var closed = open
        closed.enabled = false
        #expect(AgentNudgeGate.bytes(gate: closed, body: "secret body", role: "backend") == nil)
        closed = open; closed.foregroundIsAgent = false
        #expect(closed.denial == "notForeground")
        closed = open; closed.idle = false
        #expect(closed.denial == "busy")
        closed = open; closed.userIdle = false
        #expect(closed.denial == "userTyping")
        closed = open; closed.composing = true
        #expect(closed.denial == "userTyping")
        closed = open; closed.bracketedPaste = true
        #expect(closed.denial == "bracketedPaste")
        closed = open; closed.nudgesThisMinute = 3
        #expect(closed.denial == "nudgeRate")
        #expect(AgentNudgeGate.bytes(gate: closed, body: "x", role: "y") == nil)
    }

    @Test func contextLinesDropNewlinesAndUnknownKeys() {
        #expect(AgentEnvelope.contextLine("cwd", "a\nb") == "cwd: a b")
        #expect(AgentEnvelope.contextLine("nope", "x") == nil)
        let long = String(repeating: "x", count: 300)
        #expect(AgentEnvelope.contextLine("pane", long)?.utf8.count == "pane: ".utf8.count + 256)
    }

    @Test func envelopeContextAndClaudeLineStayBounded() {
        let text = AgentEnvelope.text(fromRole: "frontend", fromID: front, number: 12, replyTo: 9,
                                      body: "look", context: ["cwd: /tmp", "branch: main"])
        #expect(text.contains("peer agent's request"))
        #expect(text.contains("cwd: /tmp\nbranch: main\n---\nlook"))
        let line = AgentPush.claudeLine(envelope: text, messageID: "cc-msg-1")
        #expect(!line.dropLast().contains("\n"))
        #expect(line.hasSuffix("\n"))
        #expect(AgentPush.codexArguments(executable: "/usr/bin/codex", thread: "abc", message: "hi")?.contains("queue") == true)
        #expect(AgentPush.codexArguments(executable: "/usr/bin/codex", thread: "a b", message: "hi") == nil)
    }

    @Test func commandShapesAndMemberPersistence() throws {
        #expect(AgentCommand.parse(["send", "m-3f2a9c1e", "--reply-to", "4", "hello", "--context"])?.context == true)
        #expect(AgentCommand.parse(["send", "backend"]) == nil)
        #expect(AgentCommand.parse(["wait", "--timeout", "999"])?.timeout == 110)
        #expect(AgentCommand.parse(["members", "--json"])?.json == true)
        let record = AgentMemberRecord(id: front, role: "frontend", sessionID: back, nudgeEnabled: false)
        let project = SpaceProjectRecord(path: "/tmp/app", sessions: [], members: [record])
        let data = try JSONEncoder().encode(SpaceState(projects: [project]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("queued"))
        let loaded = try JSONDecoder().decode(SpaceState.self, from: data)
        #expect(loaded.projects[0].members == [record])
        let legacy = try JSONDecoder().decode(
            SpaceState.self, from: Data(#"{"version":1,"projects":[{"path":"/tmp/app"}]}"#.utf8))
        #expect(legacy.projects[0].members.isEmpty)
    }

    @Test func aDownForwardIsReportedAndNotQueued() {
        var bus = makeBus()
        bus.setHost(back, "remote")
        bus.forwardsDown.insert(back)
        #expect(bus.send(from: front, to: AgentEnvelope.shortID(back), body: "x", replyTo: nil,
                         context: [], now: 0).1 == .forwardUnavailable)
        #expect(bus.items.isEmpty)
    }
}
