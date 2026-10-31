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

/// NDJSON messages are read one line at a time, including coalesced and split writes.
nonisolated enum AgentMCP {
    static let tools = ["members", "whoami", "send", "read", "wait", "status"]

    static func definitions() -> [[String: Any]] {
        tools.map { operation in
            var properties: [String: Any] = [:]
            var required: [String] = []
            switch operation {
            case "send":
                properties = ["to": ["type": "string"], "body": ["type": "string"],
                              "reply_to": ["type": "integer"], "context": ["type": "boolean"]]
                required = ["to", "body"]
            case "read": properties = ["since": ["type": "integer"]]
            case "wait": properties = ["timeout": ["type": "integer", "minimum": 1, "maximum": 55]]
            case "status": properties = ["message_id": ["type": "integer"]]; required = ["message_id"]
            default: break
            }
            return ["name": "corta_" + operation, "description": "Corta project member " + operation,
                    "inputSchema": ["type": "object", "properties": properties, "required": required,
                                    "additionalProperties": false]]
        }
    }

    static func response(_ object: [String: Any], environment: [String: String]) -> [String: Any]? {
        guard let id = object["id"] else { return nil }
        let method = object["method"] as? String ?? ""
        let base: [String: Any] = ["jsonrpc": "2.0", "id": id]
        var response = base
        switch method {
        case "initialize":
            let params = object["params"] as? [String: Any]
            response["result"] = ["protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                                  "capabilities": ["tools": [:]], "serverInfo": ["name": "corta", "version": "1"]]
        case "ping": response["result"] = [:]
        case "tools/list": response["result"] = ["tools": definitions()]
        case "tools/call": response["result"] = call(object["params"] as? [String: Any] ?? [:],
            environment: environment)
        default: response["error"] = ["code": -32601, "message": "Method not found"]
        }
        return response
    }

    private static func call(_ params: [String: Any], environment: [String: String]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let operation = String(name.dropFirst("corta_".count))
        guard name.hasPrefix("corta_"), tools.contains(operation),
              let path = DiagnosticsEnvironment.agentSocket(in: environment) else {
            return ["isError": true, "content": [["type": "text", "text": "refused(unavailable)"]]]
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let request = AgentRequest(
            operation: operation, to: args["to"] as? String, body: args["body"] as? String,
            replyTo: (args["reply_to"] ?? args["replyTo"]) as? Int,
            timeout: args["timeout"] as? Int, number: (args["message_id"] ?? args["number"]) as? Int,
            context: args["context"] as? Bool, pane: DiagnosticsEnvironment.agentPane(in: environment),
            since: args["since"] as? Int)
        let reply = operation == "wait"
            ? AgentClient.waitReply(request, socketPath: path, seconds: min(request.timeout ?? 55, 55))
            : AgentClient.exchange(request, socketPath: path)
        return ["isError": reply?.ok != true,
                "content": [["type": "text", "text": reply?.text ?? "refused(unavailable)"]]]
    }

    static func run(environment: [String: String]) -> Int32 {
        while let data = SSHAskpass.readLine(from: STDIN_FILENO, limit: AgentEnvelope.bodyLimit * 6 + 8192) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = response(object, environment: environment),
                  let encoded = try? JSONSerialization.data(withJSONObject: response) else { continue }
            guard SSHAskpass.writeLine(encoded, to: STDOUT_FILENO) else { return 1 }
        }
        return 0
    }
}
