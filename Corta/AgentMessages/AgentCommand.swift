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

/// `corta` argv, without talking to the app.
nonisolated enum AgentCommand {
    struct Invocation: Equatable, Sendable {
        var operation: String
        var token: String?
        var body: String?
        var replyTo: Int?
        var timeout: Int?
        var json: Bool = false
        var context: Bool = false
        var number: Int?
        var since: Int?
    }

    static func parse(_ arguments: [String]) -> Invocation? {
        var args = arguments
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        let context = args.contains("--context")
        args.removeAll { $0 == "--context" }
        guard let operation = args.first else { return nil }
        switch operation {
        case "members", "whoami":
            guard args.count == 1 else { return nil }
            return Invocation(operation: operation, json: json, context: context)
        case "read":
            if args.count == 1 { return Invocation(operation: operation, json: json) }
            guard args.count == 3, args[1] == "--since", let since = Int(args[2]), since >= 0 else { return nil }
            return Invocation(operation: operation, json: json, since: since)
        case "status":
            guard args.count == 2, let number = Int(args[1]) else { return nil }
            return Invocation(operation: operation, json: json, context: context, number: number)
        case "wait":
            if args.count == 1 { return Invocation(operation: operation, timeout: 110, json: json) }
            guard args.count == 3, args[1] == "--timeout", let value = Int(args[2]) else { return nil }
            return Invocation(operation: operation, timeout: min(max(value, 1), 110), json: json)
        case "send":
            var rest = Array(args.dropFirst())
            var reply: Int?
            if let flag = rest.firstIndex(of: "--reply-to") {
                guard rest.indices.contains(flag + 1), let number = Int(rest[flag + 1]), number > 0 else { return nil }
                reply = number
                rest.removeSubrange(flag...flag + 1)
            }
            guard rest.count >= 2 else { return nil }
            return Invocation(operation: "send", token: rest[0], body: rest.dropFirst().joined(separator: " "),
                              replyTo: reply, json: json, context: context)
        case "mcp":
            return Invocation(operation: "mcp", json: false, context: false)
        default:
            return nil
        }
    }
}
