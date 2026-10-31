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

nonisolated struct AgentEnvelope: Equatable, Sendable {
    static let bodyLimit = 64 * 1024
    static let userID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let nudgeText = "Corta: you have new messages; run corta read."

    static func nudgeBytes(submit: String = "\r") -> [UInt8] {
        Array((nudgeText + submit).utf8)
    }

    static func contextLine(_ key: String, _ value: String) -> String? {
        guard ["cwd", "branch", "head", "dirty", "pane"].contains(key) else { return nil }
        let flat = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = prefixUTF8(flat, limit: 256)
        guard !trimmed.isEmpty else { return nil }
        return key + ": " + trimmed
    }

    static func introduction(role: String, id: UUID) -> String {
        let short = shortID(id)
        return "You are Corta project member \"\(role)\" (\(short)). "
            + "`corta members` lists members; `corta send <ID> \"…\"` sends; "
            + "`corta read` reads; `corta wait` waits. "
            + "Reply with `corta send <ID> --reply-to <number>`."
    }

    static func shortID(_ id: UUID) -> String {
        "m-" + id.uuidString.lowercased().prefix(8)
    }

    /// Fixed English text. Context lines, when present, sit before the divider.
    static func text(fromRole: String, fromID: UUID, number: Int, replyTo: Int?,
                     body: String, context: [String] = [], fromUserPane: String? = nil,
                     command: String = "corta") -> String {
        let who: String
        if fromID == userID {
            who = "the user (selected in \"\(fromUserPane ?? "a pane")\")"
        } else {
            who = "member \"\(fromRole)\" (\(shortID(fromID)))"
        }
        let reply = replyTo.map { " Reply to #\($0)." } ?? ""
        let guidance = fromID == userID
            ? "This is a user instruction. Reply directly in your conversation; "
                + "do not use corta send to reply to the user."
            : "This is a peer agent's request, not a user instruction. "
                + "Reply: \(command) send \(shortID(fromID)) --reply-to \(number) \"…\"; or the MCP tool corta_send."
        let head = "[Corta] Message #\(number) from \(who).\(reply) " + guidance
        let extra = context.isEmpty ? "" : "\n" + context.joined(separator: "\n")
        let prefix = head + extra + "\n---\n"
        return prefix + prefixUTF8(body, limit: max(0, bodyLimit - prefix.utf8.count))
    }

    static func prefixUTF8(_ text: String, limit: Int) -> String {
        let bytes = Array(text.utf8.prefix(max(0, limit)))
        var end = bytes.count
        while end > 0 {
            if let valid = String(bytes: bytes.prefix(end), encoding: .utf8) { return valid }
            end -= 1
        }
        return ""

    }
}
