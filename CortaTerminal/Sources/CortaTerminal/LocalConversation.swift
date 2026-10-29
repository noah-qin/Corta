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

/// Only the identity needed to fill a CLI's own resume command. Never a path or transcript.
public struct LocalConversation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case claude, codex

        public init?(processName: String) {
            switch processName {
            case "claude", "claude-code": self = .claude
            case "codex": self = .codex
            default: return nil
            }
        }
    }

    public let kind: Kind
    public let id: UUID

    public init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    /// UUID's permissive parser alone also accepts nonstandard spellings.
    public static func standardUUID(_ text: String) -> UUID? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text),
              uuid.uuidString.lowercased() == text.lowercased() else { return nil }
        return uuid
    }

    public var command: String {
        let prefix = kind == .claude ? "claude --resume " : "codex resume "
        return prefix + id.uuidString.lowercased()
    }

    /// Only file names, never file contents or a directory's newest entry.
    /// More than one distinct candidate is ambiguous, so no update is made.
    public static func openedFiles(processName: String, paths: [String]) -> LocalConversation? {
        guard let kind = Kind(processName: processName) else { return nil }
        let ids = Set(paths.compactMap { path -> UUID? in
            let file = URL(fileURLWithPath: path)
            guard file.pathExtension == "jsonl" else { return nil }
            let stem = file.deletingPathExtension().lastPathComponent
            if let uuid = standardUUID(stem) { return uuid }
            // Codex's rollout file has a timestamp before the standard UUID.
            if kind == .codex, stem.hasPrefix("rollout-"), stem.count > 44,
               stem.dropLast(36).hasSuffix("-") {
                return standardUUID(String(stem.suffix(36)))
            }
            return nil
        })
        guard ids.count == 1, let id = ids.first else { return nil }
        return LocalConversation(kind: kind, id: id)
    }
}
