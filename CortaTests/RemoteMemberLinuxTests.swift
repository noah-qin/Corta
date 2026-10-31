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
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CORTA_LINUX_TEST_ROOT"] != nil,
                            "Opt-in designated Linux host; no remote AI is launched"))
struct RemoteMemberLinuxTests {
    @Test func linuxClientSurvivesReattachAndRejectsOldAndForgedCredentials() async throws {
        let fixture = try Fixture()
        do { try await exercise(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func exercise(_ fixture: Fixture) async throws {
        try fixture.connect()
        try await wait(fixture) { fixture.hub.remoteReady.contains(fixture.remote.id) }
        let body = "quotes \" and ' and \\ plus\nnew line\tand tab"
        let sent = fixture.hub.exchange(AgentRequest(operation: "send", to: fixture.remote.id.uuidString, body: body),
                                        caller: fixture.local.id)
        #expect(sent.ok)
        let read = try await fixture.run("/tmp/" + fixture.tmux.sessionName + "/corta read --json")
        let reply = try JSONDecoder().decode(AgentReply.self, from: Data(read.utf8))
        #expect(reply.ok)
        #expect(reply.text.hasSuffix(body))
        let send = try await fixture.run("/tmp/" + fixture.tmux.sessionName + "/corta send "
                                        + fixture.local.id.uuidString + " - --json", input: body)
        #expect(try JSONDecoder().decode(AgentReply.self, from: Data(send.utf8)).ok)
        #expect(fixture.hub.bus.peek(member: fixture.local.id).last?.body == body)
        let pidCommand = "tmux display-message -p -t '=\(fixture.tmux.sessionName):0.0' '#{pane_pid}'"
        let before = try await fixture.run(pidCommand)
        let oldToken = fixture.token
        fixture.disconnect()
        #expect(fixture.hub.exchange(AgentRequest(operation: "send", to: fixture.remote.id.uuidString, body: "offline"),
                                     caller: fixture.local.id).delivery == "forwardUnavailable")
        try fixture.connect()
        try await wait(fixture) { fixture.hub.remoteReady.contains(fixture.remote.id) }
        let after = try await fixture.run(pidCommand)
        #expect(before.trimmingCharacters(in: .whitespacesAndNewlines)
            == after.trimmingCharacters(in: .whitespacesAndNewlines))
        for (token, name) in [(oldToken, fixture.tmux.sessionName), (fixture.token, "corta-forged")] {
            let request = AgentRequest(operation: "whoami", token: token, tmux: name)
            let data = try JSONEncoder().encode(request)
            let denied = try await fixture.run("nc -w 2 -U /tmp/corta-" + fixture.token + ".sock",
                                               input: String(decoding: data, as: UTF8.self) + "\n")
            #expect(try JSONDecoder().decode(AgentReply.self, from: Data(denied.utf8)).ok == false)
        }
        let fresh = try await fixture.run("/tmp/" + fixture.tmux.sessionName + "/corta whoami --json")
        #expect(try JSONDecoder().decode(AgentReply.self, from: Data(fresh.utf8)).ok)
        print("REAL LINUX protocol both directions, same tmux PID, old/forged token refused")
    }

    private func wait(_ fixture: Fixture, _ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now.advanced(by: .seconds(15))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if !predicate() {
            let diagnostic = try? await fixture.run("/tmp/" + fixture.tmux.sessionName + "/corta whoami --json 2>&1")
            print("Linux client diagnostic: " + (diagnostic ?? "client process failed"))
        }
        try #require(predicate(), "Linux forward did not become ready")
    }

    @MainActor private final class Fixture {
        let root: URL
        let localRoot: URL
        let target: String
        let hub = AgentHub()
        let local = AgentMemberRecord(role: "local", sessionID: UUID())
        let remote = AgentMemberRecord(role: "remote", sessionID: UUID(), host: "Linux acceptance")
        let tmux = RemoteTmux(id: UUID())
        var token = ""
        var tokens: [String] = []
        var connections: [Process] = []
        var inputs: [Pipe] = []

        init() throws {
            root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CORTA_LINUX_TEST_ROOT"]))
            target = try String(contentsOf: root.appendingPathComponent("target"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            localRoot = URL(fileURLWithPath: "/private/tmp/lm-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            hub.apply(enabled: true, development: true, executable: try #require(Bundle.main.executablePath),
                      directoryOverride: localRoot.path)
            try #require(hub.socketPath != nil)
            hub.sync(members: [local, remote], bound: [local.sessionID], shells: [getpid(): local.sessionID])
        }

        var arguments: [String] {
            ["-o", "ConnectTimeout=10", "-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=yes",
             "-o", "UserKnownHostsFile=" + root.appendingPathComponent("known_hosts").path]
        }

        var environment: [String: String] {
            var result = ProcessInfo.processInfo.environment
            result["SSH_ASKPASS_REQUIRE"] = "force"
            result["SSH_ASKPASS"] = root.appendingPathComponent("askpass").path
            result["DISPLAY"] = "corta"
            result["TERM"] = "xterm-256color"
            return result
        }

        func connect() throws {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            tokens.append(token)
            hub.rememberRemote(token: token, member: remote.id)
            let endpoint = try #require(hub.remoteEndpoint(token: token, member: remote.id, tmux: tmux.sessionName))
            var extras = RemoteTmux.Extras()
            extras.environmentName = "CORTA_MEMBER_TOKEN"
            extras.environmentValue = token
            extras.reverseRemote = "/tmp/corta-" + token + ".sock"
            extras.reverseLocal = endpoint
            extras.installRemoteClient = true
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments + RemoteTmux.forwardArguments(extras) + ["-tt", target,
                tmux.command(extras: extras)]
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            let logURL = URL(fileURLWithPath: "/tmp/corta-linux-last-ssh.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            process.standardOutput = log
            process.standardError = log
            try process.run()
            inputs.append(input)
            connections.append(process)
            hub.sync(members: [local, remote], bound: [local.sessionID],
                     shells: [getpid(): local.sessionID, process.processIdentifier: remote.sessionID])
        }

        func disconnect() {
            hub.disconnectRemote(remote.id)
            for process in connections where process.isRunning { process.terminate() }
        }

        func run(_ command: String, input: String = "") async throws -> String {
            let args = arguments + [target, command]
            let environment = self.environment
            return try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = args
                process.environment = environment
                let source = Pipe(), output = Pipe()
                process.standardInput = source
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                source.fileHandleForWriting.write(Data(input.utf8))
                try source.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    print("Linux command exit \(process.terminationStatus): "
                        + String(decoding: data.prefix(2048), as: UTF8.self))
                    throw NSError(domain: "LinuxFixture", code: Int(process.terminationStatus))
                }
                return String(decoding: data, as: UTF8.self)
            }.value
        }

        func cleanup() async {
            disconnect()
            let sockets = tokens.map { "/tmp/corta-" + $0 + ".sock" }.joined(separator: " ")
            let command = "tmux kill-session -t '=\(tmux.sessionName)' 2>/dev/null; "
                + "rm -rf -- /tmp/\(tmux.sessionName); rm -f -- " + sockets
            _ = try? await run(command)
            hub.stop()
            for input in inputs { try? input.fileHandleForWriting.close() }
            try? FileManager.default.removeItem(at: localRoot)
        }
    }
}
