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
enum AgentClient {
    static func runIfInvoked(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32? {
        let name = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        guard name == "corta" else { return nil }
        let rest = Array(arguments.dropFirst())
        if rest.first == "mcp" { return runMCP(environment: environment) }
        guard let invocation = AgentCommand.parse(rest) else {
            FileHandle.standardError.write(Data("usage: corta members|send|read|wait|status|whoami|mcp\n".utf8))
            return 2
        }
        guard let path = environment["CORTA_AGENT_SOCKET"] else {
            FileHandle.standardError.write(Data("agent messages are off\n".utf8))
            return 1
        }
        let request = AgentRequest(
            op: invocation.operation, to: invocation.token, body: invocation.body,
            replyTo: invocation.replyTo, timeout: invocation.timeout, number: invocation.number,
            context: invocation.context ? true : nil, pane: environment["CORTA_PANE_ID"], token: nil)
        guard let reply = exchange(request, socketPath: path) else {
            FileHandle.standardError.write(Data("refused(unavailable)\n".utf8))
            return 1
        }
        let output = invocation.json ? (try? JSONEncoder().encode(reply)).map { String(decoding: $0, as: UTF8.self) } ?? reply.text : reply.text
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
        return reply.ok ? 0 : 1
    }

    static func exchange(_ request: AgentRequest, socketPath: String) -> AgentReply? {
        guard var address = SSHAskpass.socketAddress(socketPath),
              let encoded = try? JSONEncoder().encode(request) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, SSHAskpass.writeLine(encoded, to: descriptor),
              let line = SSHAskpass.readLine(from: descriptor, limit: AgentEnvelope.bodyLimit + 8192) else { return nil }
        return try? JSONDecoder().decode(AgentReply.self, from: line)
    }

    /// A small stdio MCP server. Tool calls use the same socket as the command.
    private static func runMCP(environment: [String: String]) -> Int32 {
        let input = FileHandle.standardInput
        while let line = try? input.read(upToCount: 1_000_000), !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            let id = object["id"]
            let method = object["method"] as? String ?? ""
            var result: Any = [:]
            switch method {
            case "initialize":
                result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "corta", "version": "1"]]
            case "tools/list":
                result = ["tools": ["corta_members", "corta_send", "corta_read", "corta_wait", "corta_status"].map {
                    ["name": $0, "description": $0, "inputSchema": ["type": "object"]]
                }]
            case "tools/call":
                let params = object["params"] as? [String: Any]
                let name = params?["name"] as? String ?? ""
                let args = params?["arguments"] as? [String: Any] ?? [:]
                let op = name.replacingOccurrences(of: "corta_", with: "")
                let request = AgentRequest(
                    op: op, to: args["to"] as? String, body: args["body"] as? String,
                    replyTo: args["replyTo"] as? Int, timeout: args["timeout"] as? Int,
                    number: args["number"] as? Int, context: args["context"] as? Bool,
                    pane: environment["CORTA_PANE_ID"], token: nil)
                let reply = environment["CORTA_AGENT_SOCKET"].flatMap { exchange(request, socketPath: $0) }
                result = ["content": [["type": "text", "text": reply?.text ?? "refused(unavailable)"]]]
            case "notifications/initialized":
                continue
            default:
                result = [:]
            }
            var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
            if let id { response["id"] = id }
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        }
        return 0
    }
}
