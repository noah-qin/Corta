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

    /// Kernel vnode time: seconds and nanoseconds, never a file read.
    public struct FileTime: Comparable, Equatable, Sendable {
        public var seconds: Int64
        public var nanoseconds: Int64

        public init(seconds: Int64, nanoseconds: Int64) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.seconds == rhs.seconds ? lhs.nanoseconds < rhs.nanoseconds : lhs.seconds < rhs.seconds
        }
    }

    /// One open descriptor. Times come from the vnode; absent times are not guessed.
    public struct OpenedFile: Equatable, Sendable {
        public var path: String
        public var modified: FileTime?
        public var created: FileTime?

        public init(path: String, modified: FileTime? = nil, created: FileTime? = nil) {
            self.path = path
            self.modified = modified
            self.created = created
        }
    }

    /// Only file names, never file contents or a directory's newest entry.
    /// Without times, more than one distinct candidate is ambiguous.
    public static func openedFiles(processName: String, paths: [String]) -> LocalConversation? {
        openedFiles(processName: processName, files: paths.map { OpenedFile(path: $0) })
    }

    /// The single open session, or the strictly newest when several standard
    /// files are held. Equal or missing times leave the previous UUID alone.
    public static func openedFiles(processName: String, files: [OpenedFile]) -> LocalConversation? {
        guard let kind = Kind(processName: processName) else { return nil }
        var candidates: [UUID: (modified: FileTime?, created: FileTime?)] = [:]
        for file in files {
            guard let id = uuid(in: file.path, kind: kind) else { continue }
            var candidate = candidates[id] ?? (nil, nil)
            if let modified = file.modified, candidate.modified.map({ $0 < modified }) ?? true {
                candidate.modified = modified
            }
            if let created = file.created, candidate.created.map({ $0 < created }) ?? true {
                candidate.created = created
            }
            candidates[id] = candidate
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1, let id = candidates.keys.first {
            return LocalConversation(kind: kind, id: id)
        }
        guard let id = newest(candidates) else { return nil }
        return LocalConversation(kind: kind, id: id)
    }

    private static func uuid(in path: String, kind: Kind) -> UUID? {
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
    }

    private static func newest(_ candidates: [UUID: (modified: FileTime?, created: FileTime?)]) -> UUID? {
        let count = candidates.count
        if let id = strictNewest(candidates.compactMap { id, candidate in candidate.modified.map { (id, $0) } },
                                 required: count) {
            return id
        }
        return strictNewest(candidates.compactMap { id, candidate in candidate.created.map { (id, $0) } },
                            required: count)
    }

    /// Every candidate must carry the time, and exactly one must be strictly latest.
    private static func strictNewest(_ timed: [(UUID, FileTime)], required: Int) -> UUID? {
        guard timed.count == required, let latest = timed.map(\.1).max() else { return nil }
        let winners = Set(timed.filter { $0.1 == latest }.map(\.0))
        return winners.count == 1 ? winners.first : nil
    }
}
