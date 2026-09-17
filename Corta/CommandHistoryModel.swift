import AppKit
import CortaTerminal
import Observation

/// B10 — the shared state model behind `CommandHistoryView`, and this
/// project's first SwiftUI surface. Everything the view reads or writes
/// lives here as plain properties instead of being read back out of live
/// `NSButton`/`NSPopUpButton` state the way the AppKit version this
/// replaces had to (`git log` has that version, in `CommandHistoryController
/// .swift`, if a future surface wants the comparison).
@MainActor
@Observable
final class CommandHistoryModel {
    enum ExitFilter: Int, CaseIterable, Identifiable {
        case any, succeeded, failed
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .any: return L10n.text("commandHistory.exitAny")
            case .succeeded: return L10n.text("commandHistory.exitSucceeded")
            case .failed: return L10n.text("commandHistory.exitFailed")
            }
        }
    }

    /// B13 — scope records by the machine they ran on. `CommandRecord.host`
    /// is set for a command begun while the pane referred to a remote host
    /// (`Performer+ShellIntegration.swift`), so "this host" and "local" are
    /// a real question the records can answer, not a guess from text.
    enum HostScope: Hashable {
        case any, local, host(String)
    }

    /// One row's already-formatted display state — computed once per
    /// `rows` access rather than per SwiftUI body evaluation, since
    /// `canFillOrRun` reads the grid (`ViewController.commandLineText`) and
    /// a window with the maximum command-history backlog should not
    /// re-walk it on every render pass.
    struct Row: Identifiable {
        let id: Int
        let statusSymbolName: String
        let statusDescription: String
        let timestamp: String
        let directoryText: String
        let directoryTooltip: String?
        /// The command as typed, recovered from the grid — `nil` once its
        /// prompt line has left the scrollback, which is also when Fill
        /// and Run stop being offered.
        let commandText: String?
        let canFillOrRun: Bool
        let accessibilityLabel: String
    }

    weak var pane: ViewController?
    var directoryOnly = false
    var projectOnly = false
    var exitFilter: ExitFilter = .any
    var hostScope: HostScope = .any
    /// B16 test pass — a history you cannot search by what was typed is a
    /// list of timestamps. Case-insensitive substring over the recovered
    /// command text; a record whose text is gone from the scrollback
    /// cannot match a non-empty query and is left out of the results.
    var query: String = ""
    /// Set by `CommandHistoryController`; called when an action (Find,
    /// successful Fill or Run) wants the window to close, same moment the
    /// AppKit version called `window?.close()` directly.
    var onDismiss: (() -> Void)?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var noPaneMessage: String? {
        pane?.session == nil ? L10n.text("commandHistory.noPane") : nil
    }

    /// The hosts this pane's records name, for the scope picker's list.
    /// Sorted rather than in record order: the list is a chooser, and a
    /// chooser that reshuffles as new commands land is unusable.
    var knownHosts: [String] {
        guard let session = pane?.session else { return [] }
        return Set(session.commandRecords.records.compactMap(\.host)).sorted()
    }

    var rows: [Row] {
        guard let pane, let session = pane.session else { return [] }
        let grid = session.snapshot()
        let directory = directoryOnly ? session.workingDirectory : nil
        let host: String? =
            switch hostScope {
            case .any, .local: nil
            case .host(let name): name
            }
        var records = session.commandRecords.records(inDirectory: directory, host: host)
        if case .local = hostScope {
            records = records.filter { $0.host == nil }
        }
        if projectOnly, let cwd = session.workingDirectory,
            let root = DirectoryHistory.projectRoot(for: cwd)
        {
            records = records.filter {
                $0.workingDirectory.flatMap { DirectoryHistory.projectRoot(for: $0) } == root
            }
        }
        switch exitFilter {
        case .any: break
        case .succeeded: records = records.filter { $0.exitStatus == 0 }
        case .failed: records = records.filter { $0.didFail }
        }
        let rows = records.map { Self.row(for: $0, grid: grid) }
        return Self.filter(rows, query: query)
    }

    /// The text filter, as a pure function so it is testable on rows built
    /// by hand.
    nonisolated static func filter(_ rows: [Row], query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.commandText?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                != nil
        }
    }

    private static func row(for record: CommandRecord, grid: Grid) -> Row {
        let symbolName: String
        let statusDescription: String
        if record.isRunning {
            symbolName = "ellipsis.circle"
            statusDescription = L10n.text("commandHistory.statusRunning")
        } else if record.didFail {
            symbolName = "xmark.circle.fill"
            statusDescription = L10n.format("commandHistory.statusFailed", record.exitStatus ?? 1)
        } else {
            symbolName = "checkmark.circle.fill"
            statusDescription = L10n.text("commandHistory.statusSucceeded")
        }
        // A remote command's column shows its host, not its
        // `workingDirectory`: on a record with a host that field is the
        // *local* directory the pane was in before going remote
        // (`CommandRecord.host`'s doc), which would label the command with
        // a place it never ran in.
        let directoryText: String
        let directoryTooltip: String?
        if let host = record.host {
            directoryText = "⟂ \(host)"
            directoryTooltip = nil
        } else {
            directoryText = record.workingDirectory.map { ($0 as NSString).lastPathComponent }
                ?? L10n.text("commandHistory.unknownDirectory")
            directoryTooltip = record.workingDirectory
        }
        let timestamp = timestampFormatter.string(from: record.startedAt)
        let commandText = ViewController.commandLineText(grid: grid, record: record)
        return Row(
            id: record.id, statusSymbolName: symbolName, statusDescription: statusDescription,
            timestamp: timestamp, directoryText: directoryText,
            directoryTooltip: directoryTooltip, commandText: commandText,
            canFillOrRun: commandText != nil,
            accessibilityLabel: L10n.format(
                "commandHistory.a11yRow", statusDescription, timestamp, directoryText,
                commandText ?? L10n.text("commandHistory.textGone")))
    }

    func clearHistory() {
        pane?.session?.clearCommandRecords()
    }

    func find(id: Int) {
        guard let pane, pane.focusCommand(id: id) else { return }
        onDismiss?()
        pane.view.window?.makeKeyAndOrderFront(nil)
        pane.view.window?.makeFirstResponder(pane.terminalView)
    }

    func fill(id: Int) {
        guard let pane, let record = record(id: id), let text = pane.commandLineText(for: record)
        else { return }
        guard pane.fillPrompt(with: text) else {
            pane.terminalView?.showToast(L10n.text("toast.cannotFillPrompt"), kind: .warning)
            return
        }
        onDismiss?()
    }

    func run(id: Int) {
        guard let pane, let record = record(id: id), let text = pane.commandLineText(for: record)
        else { return }
        guard pane.fillAndRunPrompt(with: text) else {
            pane.terminalView?.showToast(L10n.text("toast.cannotFillPrompt"), kind: .warning)
            return
        }
        onDismiss?()
    }

    private func record(id: Int) -> CommandRecord? {
        pane?.session?.commandRecords.records.first { $0.id == id }
    }
}
