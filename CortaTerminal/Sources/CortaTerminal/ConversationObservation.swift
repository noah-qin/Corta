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

/// A kernel identity, including subsecond start time, never persisted in Space.
public struct ConversationProcess: Hashable, Sendable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64
    public let name: String

    public init(pid: Int32, seconds: UInt64, microseconds: UInt64, name: String) {
        self.pid = pid
        self.seconds = seconds
        self.microseconds = microseconds
        self.name = name
    }

    static func read(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let name = PTY.processName(of: pid) else { return nil }
        let recognizedName: String
        if LocalConversation.Kind(processName: name) == nil,
           let invocation = invocationName(pid), LocalConversation.Kind(processName: invocation) != nil {
            recognizedName = invocation
        } else {
            recognizedName = name
        }
        return Self(pid: pid, seconds: info.pbi_start_tvsec,
                    microseconds: info.pbi_start_tvusec, name: recognizedName)
    }
    /// Native Claude installs execute a version-named symlink target. `ps comm`
    /// still calls it claude: use only argv[0], never decode later arguments/environment.
    public static func invocationName(_ pid: pid_t) -> String? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &bytes, &length, nil, 0) == 0 else { return nil }
        return invocationName(bytes: Array(bytes.prefix(length)))
    }

    static func invocationName(bytes: [UInt8]) -> String? {
        // argc, executable path, NUL padding, argv[0], then arguments/environment.
        let offset = MemoryLayout<Int32>.size
        guard bytes.count > offset, let pathEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        var start = pathEnd
        while start < bytes.count, bytes[start] == 0 { start += 1 }
        guard start < bytes.count, let end = bytes[start...].firstIndex(of: 0), end > start else { return nil }
        let invocation = String(decoding: bytes[start..<end], as: UTF8.self)
        return URL(fileURLWithPath: invocation).lastPathComponent
    }

}

/// Both the result and the reason are injectable/testable without reading system logs.
public struct ConversationObservation: Equatable, Sendable {
    public enum Reason: String, Error, Sendable {
        case recordMissing, recordUnreadable, recordTooLarge, fieldMissing, notStandardUUID
        case processMismatch, noOpenFile, ambiguousOpenFiles, openFilesUnreadable, sessionChanged
    }

    public let conversation: LocalConversation
    public let processes: [ConversationProcess]
    public let reason: Reason?
    /// The record file's stat changed and this sample is not the previous conversation.
    public let sessionChanged: Bool

    public init(kind: LocalConversation.Kind, processes: [ConversationProcess],
                id: UUID? = nil, source: LocalConversation.Source = .picker, reason: Reason? = nil,
                sessionChanged: Bool = false) {
        conversation = LocalConversation(kind: kind, id: id, source: source)
        self.processes = processes
        self.reason = reason
        self.sessionChanged = sessionChanged
    }

    /// Logged once. Later samples of the same stamp do not repeat it.
    public func settled() -> ConversationObservation {
        guard sessionChanged else { return self }
        return ConversationObservation(
            kind: conversation.kind, processes: processes, id: conversation.id,
            source: conversation.source, reason: reason)
    }

    /// A transient failed probe of the same agent must not erase a verified UUID.
    /// A same-process record change that cannot be confirmed drops it.
    /// A different PID/start time replaces it, even if only the kind is available.
    public func retainingIdentity(_ previous: LocalConversation?,
                                  previousProcesses: [ConversationProcess]?) -> LocalConversation {
        if sessionChanged { return conversation }
        guard conversation.id == nil, previousProcesses == processes, let previous,
              previous.kind == conversation.kind, previous.id != nil else { return conversation }
        return previous
    }

    static func codex(processes: [ConversationProcess], files: [LocalConversation.OpenedFile]?) -> Self {
        guard let files else { return Self(kind: .codex, processes: processes, reason: .openFilesUnreadable) }
        let conversation = LocalConversation.openedFiles(processName: "codex", files: files)
        let hasCandidate = files.contains {
            LocalConversation.openedFiles(processName: "codex", files: [$0]) != nil
        }
        return Self(kind: .codex, processes: processes, id: conversation?.id, source: .openFile,
                    reason: conversation == nil ? (hasCandidate ? .ambiguousOpenFiles : .noOpenFile) : nil)
    }

    static func recognized(_ members: [ConversationProcess]) -> (LocalConversation.Kind, [ConversationProcess])? {
        let agents = members.filter { LocalConversation.Kind(processName: $0.name) != nil }
        let kinds = Set(agents.compactMap { LocalConversation.Kind(processName: $0.name)?.rawValue })
        guard kinds.count == 1, let first = agents.first,
              let kind = LocalConversation.Kind(processName: first.name) else { return nil }
        return (kind, agents.sorted { $0.pid < $1.pid })
    }
}

/// An absent sample preserves exit history; confirmed mixed tools erase it.
public enum ConversationSample: Equatable, Sendable {
    case observed(ConversationObservation)
    case mixedProcesses

    static func isMixed(_ members: [ConversationProcess]) -> Bool {
        Set(members.compactMap { LocalConversation.Kind(processName: $0.name) }).count > 1
    }
}

/// Claude's undocumented accelerator. Failure always preserves the official picker.
/// Only identity fields are decoded; no transcript or other fields leave this reader.
enum ClaudeSessionRecord {
    static let maximumBytes = 64 * 1024

    /// `(dev, inode, size, mtime)`. Compared before any read of the file.
    struct FileStamp: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var seconds: Int64
        var nanoseconds: Int64
    }

    /// `lstat`: a symlink is visible and is not followed. Missing is nil.
    static func stamp(process: ConversationProcess, directory: URL) -> FileStamp? {
        var metadata = stat()
        let path = directory.appendingPathComponent(String(process.pid) + ".json").path
        guard lstat(path, &metadata) == 0 else { return nil }
        return FileStamp(
            device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: metadata.st_size,
            seconds: Int64(metadata.st_mtimespec.tv_sec), nanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
    }

    private struct Identity: Decodable {
        let sessionId: String?
        let pid: Int32?
        let procStart: String?
    }

    static func read(process: ConversationProcess, directory: URL,
                     verify: () -> Bool) -> ConversationObservation {
        func fallback(_ reason: ConversationObservation.Reason) -> ConversationObservation {
            ConversationObservation(kind: .claude, processes: [process], reason: reason)
        }
        guard verify() else { return fallback(.processMismatch) }
        let data: Data
        switch load(process: process, directory: directory) {
        case .success(let contents): data = contents
        case .failure(let reason): return fallback(reason)
        }
        guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
            return fallback(.recordUnreadable)
        }
        guard let raw = identity.sessionId else { return fallback(.fieldMissing) }
        guard let uuid = LocalConversation.standardUUID(raw) else { return fallback(.notStandardUUID) }
        guard identity.pid == process.pid, let start = identity.procStart,
              normalized(start) == normalized(startString(seconds: process.seconds)), verify() else {
            return fallback(.processMismatch)
        }
        return ConversationObservation(kind: .claude, processes: [process], id: uuid, source: .sessionRecord)
    }

    private static func load(process: ConversationProcess, directory: URL)
        -> Result<Data, ConversationObservation.Reason>
    {
        let path = directory.appendingPathComponent(String(process.pid) + ".json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(errno == ENOENT ? .recordMissing : .recordUnreadable)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return .failure(.recordUnreadable)
        }
        guard metadata.st_size <= maximumBytes else { return .failure(.recordTooLarge) }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return .failure(.recordUnreadable)
            }
            if readCount == 0 { break }
            count += readCount
        }
        guard count <= maximumBytes else { return .failure(.recordTooLarge) }
        return .success(Data(bytes.prefix(count)))
    }

    /// Claude Code 2.1.312 uses `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`.
    /// Compare the kernel start second in that exact timezone, never a guessed date format.
    static func startString(seconds: UInt64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}

/// One agent per pane. A success is cached by PID, kernel start and the
/// record file's stat four-tuple; a changed stamp is read once.
struct ClaudeConversationCache: Sendable {
    static let maximumAttempts = 3
    private var process: ConversationProcess?
    private var stamp: ClaudeSessionRecord.FileStamp?
    private var observation: ConversationObservation?
    private var attempts = 0
    private var lastReason: ConversationObservation.Reason = .recordMissing
    /// The stamp already charged against the failure budget. An unchanged file is not read again.
    private var failedStamp: ClaudeSessionRecord.FileStamp?

    mutating func read(process: ConversationProcess, directory: URL,
                       verify: () -> Bool) -> ConversationObservation {
        if self.process != process {
            self.process = process
            observation = nil
            stamp = nil
            failedStamp = nil
            attempts = 0
            lastReason = .recordMissing
        }
        let current = ClaudeSessionRecord.stamp(process: process, directory: directory)
        if let observation, current == stamp { return observation }
        if let failedStamp, current == failedStamp {
            return ConversationObservation(kind: .claude, processes: [process], reason: lastReason)
        }
        let hadIdentity = observation?.conversation.id != nil
        if current == nil {
            observation = nil
            stamp = nil
            failedStamp = nil
            return ConversationObservation(
                kind: .claude, processes: [process], reason: .recordMissing, sessionChanged: hadIdentity)
        }
        guard attempts < Self.maximumAttempts else {
            observation = nil
            stamp = current
            failedStamp = current
            return ConversationObservation(
                kind: .claude, processes: [process], reason: lastReason, sessionChanged: hadIdentity)
        }
        let result = ClaudeSessionRecord.read(process: process, directory: directory, verify: verify)
        let previous = observation?.conversation.id
        stamp = current
        if let reason = result.reason {
            lastReason = reason
            if reason != .recordMissing { attempts += 1 }
            observation = nil
            failedStamp = current
            let switched = hadIdentity
            return ConversationObservation(
                kind: .claude, processes: [process], reason: reason, sessionChanged: switched)
        }
        failedStamp = nil
        attempts = 0
        let switched = previous != nil && previous != result.conversation.id
        let stored = ConversationObservation(
            kind: .claude, processes: [process], id: result.conversation.id, source: .sessionRecord)
        observation = stored
        return switched ? ConversationObservation(
            kind: .claude, processes: [process], id: result.conversation.id, source: .sessionRecord,
            sessionChanged: true) : stored
    }
}
