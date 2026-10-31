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

@MainActor
@Suite(.serialized)
struct AgentProtocolIntegrationTests {
    @Test func nativeMCPHandlesSplitAndCoalescedLinesWithoutReplyingToNotifications() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/mcp-" + UUID().uuidString.prefix(8))
        let hub = AgentHub()
        hub.apply(enabled: true, development: true, executable: try #require(Bundle.main.executablePath),
                  directoryOverride: root.path)
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }
        let member = AgentMemberRecord(role: "pipe-member", sessionID: UUID())
        hub.sync(members: [member], bound: [member.sessionID], shells: [getpid(): member.sessionID])
        let socket = try #require(hub.socketPath)
        let executable = root.appendingPathComponent("bin/corta").path
        let pane = member.sessionID.uuidString
        let output = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["mcp"]
            process.environment = ["CORTA_AGENT_SOCKET": socket, "CORTA_PANE_ID": pane]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"init"#.utf8))
            try await Task.sleep(for: .milliseconds(20))
            let rest = """
            ialize","params":{"protocolVersion":"2025-03-26"}}
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"corta_members","arguments":{}}}

            """
            input.fileHandleForWriting.write(Data(rest.utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        let replies = try String(decoding: output, as: UTF8.self).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(replies.count == 3)
        #expect(replies.allSatisfy { $0["error"] == nil })
        #expect(String(decoding: output, as: UTF8.self).contains("pipe-member"))
    }

    @Test func remoteCredentialsAreBoundToTheirPrivateEndpointAndRevokedOnPause() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/grant-" + UUID().uuidString.prefix(8))
        let hub = AgentHub()
        hub.apply(enabled: true, development: true, executable: try #require(Bundle.main.executablePath),
                  directoryOverride: root.path)
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }
        var first = AgentMemberRecord(role: "first", sessionID: UUID(), host: "test-host")
        let second = AgentMemberRecord(role: "second", sessionID: UUID(), host: "test-host")
        hub.sync(members: [first, second], bound: [], shells: [:])
        hub.rememberRemote(token: "first-credential", member: first.id)
        hub.rememberRemote(token: "second-credential", member: second.id)
        let firstPath = try #require(hub.remoteEndpoint(token: "first-credential",
                                                       member: first.id, tmux: "first-tmux"))
        let secondPath = try #require(hub.remoteEndpoint(token: "second-credential",
                                                        member: second.id, tmux: "second-tmux"))
        let shared = try #require(hub.socketPath)
        let request = AgentRequest(operation: "whoami", token: "first-credential", tmux: "first-tmux")
        for (path, allowed) in [(firstPath, true), (secondPath, false), (shared, false)] {
            let reply = await Task.detached { AgentClient.exchange(request, socketPath: path) }.value
            #expect(reply?.ok == allowed)
        }
        first.paused = true
        hub.sync(members: [first, second], bound: [], shells: [:])
        #expect(hub.caller(token: "first-credential") == nil)
        #expect(!FileManager.default.fileExists(atPath: firstPath))
        let refused = await Task.detached { AgentClient.exchange(request, socketPath: firstPath) }.value
        #expect(refused == nil)
    }

    @Test func realSocketRoundTripChecksTheCallerAndProject() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agent-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = AgentHub()
        let sender = AgentMemberRecord(role: "front", sessionID: UUID())
        let receiver = AgentMemberRecord(role: "back", sessionID: UUID())
        let outsider = AgentMemberRecord(role: "other-project", sessionID: UUID())
        let executable = try #require(Bundle.main.executablePath)
        hub.apply(enabled: true, development: true, executable: executable, directoryOverride: root.path)
        defer { hub.stop() }
        hub.sync(members: [sender, receiver, outsider], bound: [sender.sessionID, receiver.sessionID,
            outsider.sessionID],
                 shells: [getpid(): sender.sessionID],
                 projects: [sender.id: "/a", receiver.id: "/a", outsider.id: "/b"])
        let path = try #require(hub.socketPath)
        let readDirectory = await Task.detached {
            AgentClient.exchange(AgentRequest(operation: "members", pane: sender.sessionID.uuidString),
                socketPath: path)
        }.value
        #expect(readDirectory?.ok == true)
        #expect(readDirectory?.text.contains("front") == true)
        #expect(readDirectory?.text.contains("other-project") == false)
        let forged = await Task.detached {
            AgentClient.exchange(AgentRequest(operation: "members", pane: receiver.sessionID.uuidString),
                socketPath: path)
        }.value
        #expect(forged?.ok == false)
        let start = hub.shellStarts[getpid()]
        hub.shellStarts[getpid()] = 0
        let stale = await Task.detached {
            AgentClient.exchange(AgentRequest(operation: "whoami"), socketPath: path)
        }.value
        #expect(stale?.ok == false)
        hub.shellStarts[getpid()] = start
        let body = "quoted \"text\"\nsecond line\t\u{1b}"
        let sent = await Task.detached {
            AgentClient.exchange(AgentRequest(operation: "send", to: receiver.id.uuidString, body: body,
                                             pane: sender.sessionID.uuidString), socketPath: path)
        }.value
        #expect(sent?.ok == true)
        hub.shells = [getpid(): receiver.sessionID]
        let read = await Task.detached {
            AgentClient.exchange(AgentRequest(operation: "read", pane: receiver.sessionID.uuidString), socketPath: path)
        }.value
        #expect(read?.text.hasSuffix(body) == true)
        let denied = hub.exchange(AgentRequest(operation: "send", to: outsider.id.uuidString, body: "no"),
            caller: sender.id)
        #expect(denied.delivery == "refused(differentProject)")
        let hidden = hub.exchange(AgentRequest(operation: "status", number: sent?.number), caller: outsider.id)
        #expect(!hidden.ok)
    }

    @Test func aWaitReturnsJSONWhenMailArrivesAndDoesNotBlockTheMainActor() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agent-wait-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = AgentHub()
        let sender = AgentMemberRecord(role: "front", sessionID: UUID())
        let receiver = AgentMemberRecord(role: "back", sessionID: UUID())
        hub.sync(members: [sender, receiver], bound: [sender.sessionID, receiver.sessionID],
                 shells: [getpid(): receiver.sessionID])
        hub.apply(enabled: true, development: true, executable: try #require(Bundle.main.executablePath),
                  directoryOverride: root.path)
        defer { hub.stop() }
        let path = try #require(hub.socketPath)
        let request = AgentRequest(operation: "read", pane: receiver.sessionID.uuidString)
        let waiting = Task.detached { AgentClient.waitReply(request, socketPath: path, seconds: 2) }
        try await Task.sleep(for: .milliseconds(200))
        let sent = hub.exchange(AgentRequest(operation: "send", to: receiver.id.uuidString, body: "arrived"),
            caller: sender.id)
        #expect(sent.ok)
        let start = SuspendingClock.now
        let reply = try #require(await waiting.value)
        #expect(start.duration(to: .now) < .seconds(1))
        let encoded = AgentClient.format(reply, json: true)
        let decoded = try JSONDecoder().decode(AgentReply.self, from: Data(encoded.utf8))
        #expect(decoded.text.contains("arrived"))
    }

    @Test func allClosedNudgeGatesWriteNoBytes() {
        let base = AgentNudgeGate(enabled: true, foregroundIsAgent: true, idle: true, userIdle: true,
                                  composing: false, bracketedPaste: false, nudgesThisMinute: 0)
        var gates = [AgentNudgeGate]()
        var gate = base; gate.enabled = false; gates.append(gate)
        gate = base; gate.foregroundIsAgent = false; gates.append(gate)
        gate = base; gate.idle = false; gates.append(gate)
        gate = base; gate.userIdle = false; gates.append(gate)
        gate = base; gate.composing = true; gates.append(gate)
        gate = base; gate.bracketedPaste = true; gates.append(gate)
        gate = base; gate.nudgesThisMinute = 3; gates.append(gate)
        for closed in gates {
            let hub = AgentHub()
            let front = AgentMemberRecord(role: "front", sessionID: UUID())
            let back = AgentMemberRecord(role: "back", sessionID: UUID())
            hub.sync(members: [front, back], bound: [front.sessionID, back.sessionID], shells: [:])
            hub.snapshot = { _ in
                AgentWakeSnapshot(kind: "kimi", claudeSocket: nil, codexExecutable: nil, codexThread: nil, gate: closed)
            }
            var writes = 0
            hub.writeNudge = { _ in writes += 1; return true }
            let reply = hub.exchange(AgentRequest(operation: "send", to: back.id.uuidString,
                body: "untrusted"), caller: front.id)
            #expect(reply.delivery == "queued")
            hub.nudgePending()
            #expect(writes == 0)
            #expect(hub.historyText(sessionID: back.sessionID).contains("gate:"))
        }
    }

    @Test func pushJSONEscapesAllControlsAndMCPDescribesArguments() throws {
        let body = "quotes \"\\\"\n\r\t\u{1b}"
        let line = AgentPush.claudeLine(envelope: body, messageID: "test")
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try #require(object["message"] as? [String: String])
        #expect(message["content"] == body)
        let definition = try #require(AgentMCP.definitions().first { $0["name"] as? String == "corta_send" })
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["to", "body"])
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        #expect(AgentMCP.response(notification, environment: [:]) == nil)
    }

    @Test func aNoisyOrHungPushIsBoundedAndTerminates() async throws {
        let start = SuspendingClock.now
        let noisy = await Task.detached {
            AgentPush.run(["/bin/sh", "-c", "exec /usr/bin/yes"], timeout: 0.5)
        }.value
        #expect(!noisy)
        #expect(start.duration(to: .now) < .seconds(3))
        let slow = await Task.detached {
            AgentPush.run(["/bin/sh", "-c", "trap : TERM; while :; do :; done"], timeout: 0.2)
        }.value
        #expect(!slow)
    }
}
