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

/// One JSON line from `corta` or from the remote `nc` client.
nonisolated struct AgentRequest: Codable, Equatable, Sendable {
    var operation: String
    var to: String?
    var body: String?
    var replyTo: Int?
    var timeout: Int?
    var number: Int?
    var context: Bool?
    var pane: String?
    var token: String?
    var tmux: String?
    var since: Int?
    enum CodingKeys: String, CodingKey {
        case operation = "op"
        case to, body, replyTo, timeout, number, context, pane, token, tmux, since
    }

}

nonisolated struct AgentReply: Codable, Equatable, Sendable {
    var ok: Bool
    var text: String
    var delivery: String?
    var number: Int?
}

/// What the pane can tell the waker without sharing the view.
struct AgentWakeSnapshot: Sendable {
    var kind: String?
    var claudeSocket: String?
    var codexExecutable: String?
    var codexThread: String?
    var gate: AgentNudgeGate
}
