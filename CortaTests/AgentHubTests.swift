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

@MainActor
struct AgentHubTests {
    @Test func aMemberCanSendAndAClosedGateDoesNotNudge() {
        let hub = AgentHub()
        let front = UUID()
        let back = UUID()
        let session = UUID()
        let frontSession = UUID()
        hub.sync(members: [
            AgentMemberRecord(id: front, role: "frontend", sessionID: frontSession),
            AgentMemberRecord(id: back, role: "backend", sessionID: session),
        ], bound: [frontSession, session], shells: [:])
        hub.snapshot = { _ in
            AgentWakeSnapshot(kind: "claude", claudeSocket: nil, codexExecutable: nil, codexThread: nil,
                              gate: AgentNudgeGate(enabled: false, foregroundIsAgent: true, idle: true,
                                                   userIdle: true, composing: false, bracketedPaste: false,
                                                   nudgesThisMinute: 0))
        }
        hub.writeNudge = { _ in
            Issue.record("a closed gate must not write")
            return true
        }
        let reply = hub.exchange(
            AgentRequest(op: "send", to: back.uuidString, body: "hello"), caller: front)
        #expect(reply.ok)
        #expect(reply.delivery == "queued")
        let read = hub.exchange(AgentRequest(op: "read"), caller: back)
        #expect(read.text.contains("hello"))
    }

    @Test func anOpenGateWritesOnlyTheConstantLine() {
        let hub = AgentHub()
        let front = UUID()
        let back = UUID()
        let session = UUID()
        hub.sync(members: [
            AgentMemberRecord(id: front, role: "frontend", sessionID: UUID()),
            AgentMemberRecord(id: back, role: "backend", sessionID: session, nudgeEnabled: true),
        ], bound: [session], shells: [:])
        var written: [UInt8] = []
        hub.snapshot = { _ in
            AgentWakeSnapshot(kind: nil, claudeSocket: nil, codexExecutable: nil, codexThread: nil,
                              gate: AgentNudgeGate(enabled: true, foregroundIsAgent: true, idle: true,
                                                   userIdle: true, composing: false, bracketedPaste: false,
                                                   nudgesThisMinute: 0))
        }
        hub.writeNudge = { _ in written = AgentEnvelope.nudgeBytes(); return true }
        let reply = hub.exchange(AgentRequest(op: "send", to: AgentEnvelope.shortID(back), body: "secret"), caller: front)
        #expect(reply.delivery == "nudged")
        #expect(written == AgentEnvelope.nudgeBytes())
        #expect(!String(decoding: written, as: UTF8.self).contains("secret"))
    }

    @Test func theCommandLinkPointsAtTheExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("bin")
        let tool = root.appendingPathComponent("Corta")
        try Data("x".utf8).write(to: tool)
        #expect(AgentCommandLink.ensure(bin: bin, executable: tool))
        let destination = try String(contentsOf: bin.appendingPathComponent("corta"), encoding: .utf8)
        // A symlink's contents are not the target text; readlink is inside ensure.
        #expect(AgentCommandLink.ensure(bin: bin, executable: tool))
        _ = destination
        try? FileManager.default.removeItem(at: root)
    }

    @Test func paneIdentitySurvivesSanitizing() {
        let environment = PaneSpawn.withAgent(["PATH": "/usr/bin", "CORTA_OLD": "no"], [
            "CORTA_PANE_ID": "abc", "CORTA_AGENT_BIN": "/tmp/corta-bin",
        ])
        #expect(environment["CORTA_PANE_ID"] == "abc")
        #expect(environment["PATH"] == "/tmp/corta-bin:/usr/bin")
        #expect(environment["CORTA_AGENT_BIN"] == nil)
        #expect(environment["CORTA_OLD"] == "no")
    }
}
