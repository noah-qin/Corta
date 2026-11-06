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

    /// Oldest first. A copy once evictions have begun, until the next
    /// compaction: read per command or per click, never per frame.
    public var records: [CommandRecord] {
        head == 0 ? storage : Array(storage[head...])
    }

    /// The window `storage[head...]` is the history. Evicting moves `head`, and
    /// the dead prefix goes in one compaction, so a flood of OSC 133 prompts
    /// costs amortized O(1) per record at any capacity. A prompt once moved the
    /// whole array, under the session's lock, for 18 bytes of output.
    private var storage: [CommandRecord] = []
    private var head = 0
    private var nextID = 0

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    public var last: CommandRecord? { head < storage.count ? storage.last : nil }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.nextID == rhs.nextID
            && lhs.storage[lhs.head...] == rhs.storage[rhs.head...]
    }

    mutating func begin(
        promptRow: Int, workingDirectory: String?, host: String? = nil, at date: Date
    ) {
        let record = CommandRecord(
            id: nextID, promptRow: promptRow, outputStartRow: nil, endRow: nil,
            startedAt: date, endedAt: nil, exitStatus: nil,
            workingDirectory: workingDirectory, host: host, promptEndColumn: nil)
        nextID += 1
        storage.append(record)
        if storage.count - head > capacity {
            head += 1
            // Half a capacity of dead records: two moves per insert at worst.
            if head >= max(16, capacity / 2) || head == storage.count {
                storage.removeFirst(head)
                head = 0
            }
        }
    }

    /// The last record's prompt, drawn again before anything ran at it: the
    /// same command-to-be, so the record moves rather than a new one opening.
    mutating func movePrompt(
        to promptRow: Int, workingDirectory: String?, host: String? = nil, at date: Date
    ) {
        guard head < storage.count else { return }
        let last = storage.count - 1
        storage[last].promptRow = promptRow
        storage[last].workingDirectory = workingDirectory
        storage[last].host = host
        storage[last].startedAt = date
        storage[last].promptEndColumn = nil
    }

    mutating func markOutputStart(_ row: Int) {
        guard head < storage.count else { return }
        storage[storage.count - 1].outputStartRow = row
    }

    mutating func markPromptEnd(column: Int) {
        guard head < storage.count else { return }
        storage[storage.count - 1].promptEndColumn = column
    }

    mutating func finish(exitStatus: Int, endRow: Int, at date: Date) {
        guard head < storage.count else { return }
        let last = storage.count - 1
        storage[last].exitStatus = exitStatus
        storage[last].endRow = endRow
        storage[last].endedAt = date
    }

    mutating func remapRows(_ remap: RowRemap) {
        for index in head..<storage.count {
            let oldPromptRow = storage[index].promptRow
            storage[index].promptRow = remap.map(oldPromptRow)
            storage[index].promptEndColumn = storage[index].promptEndColumn.flatMap {
                remap.promptEndColumn(promptRow: oldPromptRow, column: $0)
            }
            storage[index].outputStartRow = storage[index].outputStartRow.map(remap.map)
            storage[index].endRow = storage[index].endRow.map(remap.map)
        }
    }

    /// The command whose output covers `absoluteRow`, finished or not.
    public func record(before absoluteRow: Int) -> CommandRecord? {
        storage[head...].last { $0.promptRow <= absoluteRow }
    }

    /// Unlike `last`, never the one still running.
    public var lastCompleted: CommandRecord? {
        storage[head...].last { !$0.isRunning }
    }

    /// Most recent first; every filter optional and independent.
    public func records(
        inDirectory directory: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        exitStatus: Int? = nil,
        host: String? = nil
    ) -> [CommandRecord] {
        storage[head...].reversed().filter { record in
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
