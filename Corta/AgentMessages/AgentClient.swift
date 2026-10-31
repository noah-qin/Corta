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

import Darwin
import Foundation

/// `corta` subcommands. The executable is a symlink to Corta; this runs before any window.
nonisolated enum AgentClient {
    static func runIfInvoked(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32? {
        let name = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        guard name == "corta" else { return nil }
        let rest = Array(arguments.dropFirst())
        if rest.first == "mcp" { return AgentMCP.run(environment: environment) }
        guard let invocation = AgentCommand.parse(rest) else {
            FileHandle.standardError.write(Data("usage: corta members|send|read|wait|status|whoami|mcp\n".utf8))
            return 2
        }
        guard let path = DiagnosticsEnvironment.agentSocket(in: environment) else {
            FileHandle.standardError.write(Data("agent messages are off\n".utf8))
            return 1
        }
        var body = invocation.body
        if body == "-" {
            guard let input = boundedInput() else {
                FileHandle.standardError.write(Data("refused(tooLarge)\n".utf8))
                return 1
            }
            body = String(decoding: input, as: UTF8.self)
        }
        let request = AgentRequest(
            operation: invocation.operation == "wait" ? "read" : invocation.operation,
            to: invocation.token, body: body,
            replyTo: invocation.replyTo, timeout: invocation.timeout, number: invocation.number,
            context: invocation.context ? true : nil, pane: DiagnosticsEnvironment.agentPane(in: environment),
                token: nil)
        if invocation.operation == "wait" {
            return wait(request, socketPath: path, seconds: invocation.timeout ?? 110, json: invocation.json)
        }
        guard let reply = exchange(request, socketPath: path) else {
            FileHandle.standardError.write(Data("refused(unavailable)\n".utf8))
            return 1
        }
        let output = format(reply, json: invocation.json)
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
        return reply.ok ? 0 : 1
    }

    private static func boundedInput() -> Data? {
        var data = Data()
        while data.count <= AgentEnvelope.bodyLimit {
            guard let next = try? FileHandle.standardInput.read(upToCount: AgentEnvelope.bodyLimit + 1 - data.count)
            else { return nil }
            if next.isEmpty { return data }
            data.append(next)
        }
        return nil
    }

    static func format(_ reply: AgentReply, json: Bool) -> String {
        guard json, let data = try? JSONEncoder().encode(reply) else { return reply.text }
        return String(decoding: data, as: UTF8.self)
    }

    static func waitReply(_ request: AgentRequest, socketPath: String, seconds: Int) -> AgentReply? {
        let deadline = SuspendingClock.now.advanced(by: .seconds(min(max(seconds, 1), 110)))
        var read = request
        read.operation = "read"
        while SuspendingClock.now < deadline {
            guard let reply = exchange(read, socketPath: socketPath) else { return nil }
            if !reply.ok || !reply.text.isEmpty { return reply }
            Thread.sleep(forTimeInterval: 0.1)
        }
        var empty = request
        empty.operation = "wait"
        return exchange(empty, socketPath: socketPath)
    }

    static func wait(_ request: AgentRequest, socketPath: String, seconds: Int, json: Bool) -> Int32 {
        guard let reply = waitReply(request, socketPath: socketPath, seconds: seconds) else {
            FileHandle.standardError.write(Data("refused(unavailable)\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(Data((format(reply, json: json) + "\n").utf8))
        return reply.ok ? 0 : 1
    }

    static func exchange(_ request: AgentRequest, socketPath: String) -> AgentReply? {
        guard var address = SSHAskpass.socketAddress(socketPath),
              let encoded = try? JSONEncoder().encode(request) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, SSHAskpass.writeLine(encoded, to: descriptor),
              let line = SSHAskpass.readLine(from: descriptor, limit: AgentEnvelope.bodyLimit * 32) else { return nil }
        return try? JSONDecoder().decode(AgentReply.self, from: line)
    }

}
