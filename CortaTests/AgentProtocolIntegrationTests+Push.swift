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
import Darwin
import Foundation
import Testing
@testable import Corta

extension AgentProtocolIntegrationTests {
    @Test func realClaudeSocketGetsExactlyOneJSONLineAndRequiresAPrivateDirectory() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/claude-wire-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("inbox.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = try #require(SSHAskpass.socketAddress(path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let capture = Task.detached {
            let deadline = SuspendingClock.now.advanced(by: .seconds(3))
            var client: Int32 = -1
            while client < 0, SuspendingClock.now < deadline {
                client = accept(listener, nil, nil)
                if client < 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
            try #require(client >= 0)
            defer { close(client) }
            // Darwin inherits the listener's nonblocking flag on accept.
            let flags = fcntl(client, F_GETFL)
            _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return SSHAskpass.readLine(from: client, limit: 128 * 1024)
        }
        let body = "peer \"quoted\"\nline\t\u{1b}"
        #expect(AgentPush.writeClaude(socket: path, envelope: body))
        let data = try #require(try await capture.value)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["message"] as? [String: Any])?["content"] as? String == body)
        #expect(json["type"] as? String == "user")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(!AgentPush.writeClaude(socket: path, envelope: "must refuse"))
    }

    @Test func failedNativePushRecordsTheFailureThenUsesOnlyTheFixedReminder() async throws {
        let hub = AgentHub()
        let sender = AgentMemberRecord(role: "front", sessionID: UUID())
        let receiver = AgentMemberRecord(role: "back", sessionID: UUID())
        hub.sync(members: [sender, receiver], bound: [sender.sessionID, receiver.sessionID], shells: [:])
        hub.snapshot = { _ in
            AgentWakeSnapshot(kind: "claude", claudeSocket: "/tmp/claude-missing/inbox.sock",
                codexExecutable: nil, codexThread: nil,
                gate: AgentNudgeGate(enabled: true, foregroundIsAgent: true, idle: true, userIdle: true,
                    composing: false, bracketedPaste: false, nudgesThisMinute: 0))
        }
        var bytes: [UInt8] = []
        hub.writeNudge = { _ in bytes += AgentEnvelope.nudgeBytes(); return true }
        let sent = hub.exchange(AgentRequest(operation: "send", to: receiver.id.uuidString, body: "untrusted body"),
                                caller: sender.id)
        let number = try #require(sent.number)
        let task = try #require(hub.deliveryTasks[number])
        #expect(await task.value == .nudged)
        #expect(bytes == AgentEnvelope.nudgeBytes())
        #expect(hub.historyText(sessionID: receiver.sessionID).contains("pushFailed"))
        #expect(hub.historyText(sessionID: receiver.sessionID).contains("nudged"))
        hub.nudgePending()
        #expect(bytes == AgentEnvelope.nudgeBytes())
    }
}
