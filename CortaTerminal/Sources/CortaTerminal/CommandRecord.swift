import Foundation

/// A single shell command, identified by a stable id rather than a row
/// (B07). A row is a document position — selection, scrollback and reflow
/// already speak in it — and it drifts: eviction renumbers scrollback, and a
/// resize can reflow a wrapped line onto a different one. An id does not, so
/// the app can tell "the command I copied a moment ago" apart from
/// "whatever is now at that row" once the viewport has scrolled or the
/// window has been resized in between.
///
/// Built from the same `OSC 133` marks `Grid+Marks.swift` already reads for
/// jumping (`promptRow`/`outputStartRow` there are the row a mark was
/// written to; here they are the row a specific command's mark landed on),
/// so the two never disagree about where a command starts and ends.
public struct CommandRecord: Sendable, Equatable, Identifiable {
    public let id: Int
    /// The absolute row of this command's prompt (`OSC 133 ; A`).
    public var promptRow: Int
    /// Where this command's output began (`OSC 133 ; C`), when the shell
    /// reported one. `nil` for a shell whose integration emits only `A` and
    /// `D` — `ViewController.commandOutputText(grid:record:)` falls back to
    /// one row past the prompt in that case.
    public var outputStartRow: Int?
    /// The row the next prompt reached (`OSC 133 ; D`'s cursor position) —
    /// where this command's output stops. `nil` while the command is still
    /// running.
    public var endRow: Int?
    public var startedAt: Date
    public var endedAt: Date?
    /// `nil` until `OSC 133 ; D` arrives.
    public var exitStatus: Int?
    /// `OSC 7`'s value at the moment the prompt started, when the shell
    /// reports one (M2.8). Not re-read at command end: a command that itself
    /// changed directory should still be found under where it was launched.
    public var workingDirectory: String?
    /// The column the cursor sat at when `OSC 133 ; B` landed on this same
    /// row (M2.8's `promptEndColumn`, kept per-record here) — where the
    /// command the user typed starts. `nil` for a multi-line prompt whose
    /// `B` landed on a later row, or a shell that never reaches `B` at all;
    /// either way `ViewController.commandLineText(grid:record:)` (B08) has
    /// no honest place to start reading from and returns `nil` rather than
    /// guessing where a prompt string ends.
    public var promptEndColumn: Int?

    public var isRunning: Bool { endedAt == nil }
    public var didFail: Bool { exitStatus.map { $0 != 0 } ?? false }
}

/// The bounded, append-only history `PerformerState.commandRecords` actually
/// is. A struct, not a class: `PerformerState` is `Sendable` and copied like
/// everything else the performer owns, and this is small enough that the
/// copy is not worth avoiding.
public struct CommandRecordStore: Sendable, Equatable {
    /// The bound a store gets when nothing more specific is asked for —
    /// generous for jumping and inspecting *recent* commands, not an audit
    /// log, and small enough that a linear walk over it costs nothing per
    /// frame. `Configuration.commandHistoryLimit` (B08) overrides this the
    /// same way `Configuration.scrollbackLines` already overrides
    /// `Scrollback.defaultLimit`.
    public static let defaultCapacity = 512

    /// Bounded for the reason scrollback is bounded: a session left running
    /// for days must not grow this without limit (`SECURITY.md`'s resource
    /// caps). Per-instance rather than a fixed constant (B08) so a session
    /// can be given a smaller or larger bound without CortaTerminal knowing
    /// anything about where that number came from.
    public let capacity: Int

    public internal(set) var records: [CommandRecord] = []
    private var nextID = 0

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    public var last: CommandRecord? { records.last }

    mutating func begin(promptRow: Int, workingDirectory: String?, at date: Date) {
        let record = CommandRecord(
            id: nextID, promptRow: promptRow, outputStartRow: nil, endRow: nil,
            startedAt: date, endedAt: nil, exitStatus: nil,
            workingDirectory: workingDirectory, promptEndColumn: nil)
        nextID += 1
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
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

    /// The command whose output covers `absoluteRow` — the most recent one
    /// whose prompt is at or before it, whether it has finished or is still
    /// running. `ViewController.viewportCommand` (B07) is the one place that
    /// additionally cares whether it finished.
    public func record(before absoluteRow: Int) -> CommandRecord? {
        records.last { $0.promptRow <= absoluteRow }
    }

    /// The most recently *completed* command — distinct from `last`, which
    /// may still be running. `ViewController.copyLastCommandOutput` and
    /// friends want this one.
    public var lastCompleted: CommandRecord? {
        records.last { !$0.isRunning }
    }

    /// B08 — records filtered by directory, time range and/or exit status,
    /// most recent first. Every filter is independent and optional; passing
    /// none returns every record. `host` is not a filter here: nothing in
    /// this store carries one yet — `workingDirectory` is already
    /// local-only by construction (`Performer+OSC.swift`'s
    /// `setWorkingDirectory`) — and a real one waits for B13's SSH context.
    public func records(
        inDirectory directory: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        exitStatus: Int? = nil
    ) -> [CommandRecord] {
        records.reversed().filter { record in
            if let directory, record.workingDirectory != directory { return false }
            if let since, record.startedAt < since { return false }
            if let until, record.startedAt > until { return false }
            if let exitStatus, record.exitStatus != exitStatus { return false }
            return true
        }
    }
}
