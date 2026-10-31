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

import CortaTerminal
import CryptoKit
import Foundation
import Testing
@testable import Corta

/// Regression contracts derived directly from #437–#444.
@MainActor
@Suite(.serialized)
struct SpaceIssueAcceptanceTests {
    private func hub() -> (AgentHub, [AgentMemberRecord]) {
        let hub = AgentHub()
        let front = AgentMemberRecord(role: "frontend", sessionID: UUID())
        let back = AgentMemberRecord(role: "backend", sessionID: UUID())
        hub.sync(members: [front, back], bound: [front.sessionID, back.sessionID], shells: [:])
        return (hub, [front, back])
    }

    @Test("#440: user selection is a user instruction and replies stay in the conversation")
    func userEnvelopeDoesNotAskForAnImpossibleBusReply() {
        let text = AgentEnvelope.text(fromRole: "user", fromID: AgentEnvelope.userID, number: 1,
                                      replyTo: nil, body: "check this", fromUserPane: "frontend")
        #expect(text.contains("frontend"))
        #expect(!text.contains("not a user instruction"))
        #expect(!text.contains("corta send " + AgentEnvelope.shortID(AgentEnvelope.userID)))
    }

    @Test("#442: the envelope, context and body together fit in 64 KiB")
    func contextConsumesTheMessageBudget() {
        let (hub, members) = hub()
        let front = members[0], back = members[1]
        let body = String(repeating: "x", count: AgentEnvelope.bodyLimit)
        let reply = hub.exchange(AgentRequest(operation: "send", to: back.id.uuidString, body: body), caller: front.id)
        if reply.ok {
            let delivered = hub.exchange(AgentRequest(operation: "read"), caller: back.id)
            #expect(delivered.text.utf8.count <= AgentEnvelope.bodyLimit)
        } else {
            #expect(reply.delivery?.hasPrefix("refused") == true)
        }
    }

    @Test("#442: multibyte context stays within 256 bytes and has no line breaks")
    func contextIsBoundedWithoutSplittingUTF8() throws {
        let line = try #require(AgentEnvelope.contextLine("pane", String(repeating: "界", count: 100)))
        #expect(line.utf8.count <= "pane: ".utf8.count + 256)
        #expect(!line.contains("\u{FFFD}"))
        let carriage = try #require(AgentEnvelope.contextLine("cwd", "a\rb\nc"))
        #expect(!carriage.contains("\r"))
        #expect(!carriage.contains("\n"))
    }

    @Test("#444: replacing a connection token invalidates the previous token")
    func aReplacedRemoteTokenCannotAuthenticate() {
        let (hub, members) = hub()
        let back = members[1]
        hub.rememberRemote(token: "old", member: back.id)
        hub.rememberRemote(token: "new", member: back.id)
        #expect(hub.caller(token: "old") == nil)
        #expect(hub.caller(token: "new") == back.id)
    }

    @Test("#444: disabling the bus revokes remote tokens")
    func stoppingRevokesRemoteTokens() {
        let (hub, members) = hub()
        let back = members[1]
        hub.rememberRemote(token: "connection", member: back.id)
        hub.markRemoteReady(back.id)
        hub.stop()
        #expect(hub.caller(token: "connection") == nil)
        #expect(hub.remoteReady.isEmpty)
    }

    @Test("#437: a successful immediate nudge is not repeated by the next refresh")
    func unreadMailDoesNotTriggerDuplicateNudges() {
        let (hub, members) = hub()
        let front = members[0], back = members[1]
        var writes = 0
        hub.snapshot = { _ in
            AgentWakeSnapshot(kind: "kimi", claudeSocket: nil, codexExecutable: nil, codexThread: nil,
                              gate: AgentNudgeGate(enabled: true, foregroundIsAgent: true, idle: true,
                                                   userIdle: true, composing: false, bracketedPaste: false,
                                                   nudgesThisMinute: 0))
        }
        hub.writeNudge = { _ in writes += 1; return true }
        let reply = hub.exchange(AgentRequest(operation: "send", to: back.id.uuidString, body: "check"),
            caller: front.id)
        #expect(reply.delivery == "nudged")
        hub.nudgePending()
        #expect(writes == 1)
    }

    @Test("#437: removing a member clears its inbox and revokes sending")
    func removedMemberCannotSendAndHasNoInbox() {
        let (hub, members) = hub()
        let front = members[0], back = members[1]
        _ = hub.exchange(AgentRequest(operation: "send", to: front.id.uuidString, body: "private request"),
            caller: back.id)
        hub.sync(members: [back], bound: [back.sessionID], shells: [:])
        #expect(hub.bus.items.isEmpty)
        let reply = hub.exchange(AgentRequest(operation: "send", to: back.id.uuidString, body: "no"), caller: front.id)
        #expect(!reply.ok)
        #expect(reply.delivery?.hasPrefix("refused") == true)
    }

    @Test("#437: a stranger cannot enumerate the member directory")
    func nonMemberCannotListMembers() {
        let (hub, _) = hub()
        #expect(!hub.exchange(AgentRequest(operation: "members"), caller: nil).ok)
    }

    @Test("#441: SSH template roundtrip preserves the retention choice")
    func templateKeepsSSHRetention() throws {
        var record = SpaceSessionRecord(number: 1, ssh: SSHTarget(host: "fixture"))
        record.retainSSH = true
        let template = SpaceTemplate.capture(name: "remote", projectPath: "/work", sessions: [record],
                                              members: [], layout: .panel(0))
        let loaded = try JSONDecoder().decode(SpaceTemplate.self, from: JSONEncoder().encode(template))
        #expect(loaded.sessions(in: "/other")[0].0.retainSSH == true)
        #expect(loaded.sessions(in: "/other")[0].0.id != record.id)
    }

    @Test("#442: a linked worktree's loose commit lives in the common git directory")
    func worktreeContextResolvesTheCommonRef() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("main/.git")
        let admin = git.appendingPathComponent("worktrees/side")
        let worktree = root.appendingPathComponent("side")
        for folder in [admin, git.appendingPathComponent("refs/heads"), worktree] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "gitdir: \(admin.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/side\n".write(to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: git.appendingPathComponent("refs/heads/side"), atomically: true, encoding: .utf8)
        #expect(GitStatusReader.read(directory: worktree.path)?.name == "side")
        #expect(GitStatusReader.commit(directory: worktree.path) == "0123456789ab")
    }

    @Test("#439: index v4 strip counts use Git's offset encoding above 127 bytes")
    func indexV4HandlesLongPreviousPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        // Independently encoded fixture: two missing files, first name 140 bytes,
        // then strip all 140 bytes (Git OFS_DELTA encoding 0x80, 0x0c), suffix z.
        var data = Data([0x44, 0x49, 0x52, 0x43, 0, 0, 0, 4, 0, 0, 0, 2])
        data.append(Data(count: 60))
        data.append(contentsOf: [0, 140, 0])
        data.append(Data(repeating: 0x61, count: 140))
        data.append(0)
        data.append(Data(count: 60))
        data.append(contentsOf: [0, 1])
        data.append(contentsOf: [0x80, 0x0c, 0x7a, 0])
        data.append(contentsOf: Insecure.SHA1.hash(data: data))
        try data.write(to: git.appendingPathComponent("index"))
        let facts = try #require(GitStatusReader.read(directory: root.path))
        #expect(!facts.unchecked)
        #expect(facts.changedFiles == 2)
    }

}
