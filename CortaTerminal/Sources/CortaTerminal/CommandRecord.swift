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

/// A shell command, identified by a stable id: a row drifts (eviction
/// renumbers scrollback, reflow moves wrapped lines), so only an id can mean
/// "the command I copied a moment ago". Built from the same OSC 133 marks
/// as `Grid+Marks.swift`, so the two agree on where a command starts.
public struct CommandRecord: Sendable, Equatable, Identifiable {
    public let id: Int
    public var promptRow: Int
    /// `nil` when the shell emits only `A` and `D`.
    public var outputStartRow: Int?
    /// Where output stops; `nil` while running.
    public var endRow: Int?
    public var startedAt: Date
    public var endedAt: Date?
    public var exitStatus: Int?
    /// Where the prompt started, not re-read at the end: a command that
    /// changed directory is found under where it was launched. Local only.
    public var workingDirectory: String?
    /// The remote host when the command began; then `workingDirectory` is
    /// the local one the pane left, not where this ran.
    public var host: String?
    /// Where the typed command starts, when `B` landed on the prompt's row;
    /// otherwise `nil`, and the command text is not guessed.
    public var promptEndColumn: Int?

    public var isRunning: Bool { endedAt == nil }
    public var didFail: Bool { exitStatus.map { $0 != 0 } ?? false }
}

/// The bounded, append-only command history.
public struct CommandRecordStore: Sendable, Equatable {
    /// Recent commands, not an audit log; small enough that a linear walk
    /// costs nothing per frame. `command-history-limit` overrides it.
    public static let defaultCapacity = 512

    /// A session left running for days must not grow this without limit.
    public let capacity: Int

    public internal(set) var records: [CommandRecord] = []
    private var nextID = 0

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    public var last: CommandRecord? { records.last }

    mutating func begin(
        promptRow: Int, workingDirectory: String?, host: String? = nil, at date: Date
    ) {
        let record = CommandRecord(
            id: nextID, promptRow: promptRow, outputStartRow: nil, endRow: nil,
            startedAt: date, endedAt: nil, exitStatus: nil,
            workingDirectory: workingDirectory, host: host, promptEndColumn: nil)
        nextID += 1
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    /// The last record's prompt, drawn again before anything ran at it: the
    /// same command-to-be, so the record moves rather than a new one opening.
    mutating func movePrompt(
        to promptRow: Int, workingDirectory: String?, host: String? = nil, at date: Date
    ) {
        guard !records.isEmpty else { return }
        let last = records.count - 1
        records[last].promptRow = promptRow
        records[last].workingDirectory = workingDirectory
        records[last].host = host
        records[last].startedAt = date
        records[last].promptEndColumn = nil
    }

    mutating func markOutputStart(_ row: Int) {
        guard !records.isEmpty else { return }
        records[records.count - 1].outputStartRow = row
    }

    mutating func markPromptEnd(column: Int) {
        guard !records.isEmpty else { return }
        records[records.count - 1].promptEndColumn = column
    }

    mutating func finish(exitStatus: Int, endRow: Int, at date: Date) {
        guard !records.isEmpty else { return }
        let last = records.count - 1
        records[last].exitStatus = exitStatus
        records[last].endRow = endRow
        records[last].endedAt = date
    }

    /// The command whose output covers `absoluteRow`, finished or not.
    public func record(before absoluteRow: Int) -> CommandRecord? {
        records.last { $0.promptRow <= absoluteRow }
    }

    /// Unlike `last`, never the one still running.
    public var lastCompleted: CommandRecord? {
        records.last { !$0.isRunning }
    }

    /// Most recent first; every filter optional and independent.
    public func records(
        inDirectory directory: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        exitStatus: Int? = nil,
        host: String? = nil
    ) -> [CommandRecord] {
        records.reversed().filter { record in
            if let directory, record.workingDirectory != directory { return false }
            if let since, record.startedAt < since { return false }
            if let until, record.startedAt > until { return false }
            if let exitStatus, record.exitStatus != exitStatus { return false }
            if let host, record.host != host { return false }
            return true
        }
    }

    public func records(onHost host: String) -> [CommandRecord] {
        records(host: host)
    }
}
