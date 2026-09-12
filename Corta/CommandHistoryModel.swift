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
        let canFillOrRun: Bool
        let accessibilityLabel: String
    }

    weak var pane: ViewController?
    var directoryOnly = false
    var projectOnly = false
    var exitFilter: ExitFilter = .any
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

    var rows: [Row] {
        guard let pane, let session = pane.session else { return [] }
        let grid = session.snapshot()
        let directory = directoryOnly ? session.workingDirectory : nil
        var records = session.commandRecords.records(inDirectory: directory)
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
        return records.map { Self.row(for: $0, grid: grid) }
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
        let directoryText = record.workingDirectory.map { ($0 as NSString).lastPathComponent }
            ?? L10n.text("commandHistory.unknownDirectory")
        let timestamp = timestampFormatter.string(from: record.startedAt)
        return Row(
            id: record.id, statusSymbolName: symbolName, statusDescription: statusDescription,
            timestamp: timestamp, directoryText: directoryText,
            directoryTooltip: record.workingDirectory,
            canFillOrRun: ViewController.commandLineText(grid: grid, record: record) != nil,
            accessibilityLabel: L10n.format(
                "commandHistory.a11yRow", statusDescription, timestamp, directoryText))
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
