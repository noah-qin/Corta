import AppKit
import CortaTerminal
import Observation

/// Cached command history and lightweight filters for the history window.
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

    /// Scope records by the machine they ran on. `CommandRecord.host`
    /// is set for a command begun while the pane referred to a remote host
    /// (`Performer+ShellIntegration.swift`), so "this host" and "local" are
    /// a real question the records can answer, not a guess from text.
    enum HostScope: Hashable {
        case any, local
        case host(String)
    }

    /// A formatted row retained until the session snapshot changes.
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

    weak var pane: ViewController? { didSet { refresh() } }
    var directoryOnly = false
    var projectOnly = false
    var exitFilter: ExitFilter = .any
    var hostScope: HostScope = .any
    /// A history you cannot search by what was typed is a list of
    /// timestamps. Case-insensitive substring over the recovered
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

    @ObservationIgnored private let projectRoot: @Sendable (String) -> String?

    init(
        projectRoot: @escaping @Sendable (String) -> String? = {
            DirectoryHistory.projectRoot(for: $0)
        }
    ) {
        self.projectRoot = projectRoot
    }

    private(set) var knownHosts: [String] = []
    private var cachedRecords: [CommandRecord] = []
    private var cachedRows: [Row] = []
    private var currentDirectory: String?
    private var projectRoots: [String: String] = [:]
    @ObservationIgnored private var snapshotStamp: [UInt64] = []

    /// Rebuild formatted rows only when the session changes, never from a body getter.
    func refresh() {
        guard let session = pane?.session else {
            cachedRecords = []
            cachedRows = []
            knownHosts = []
            currentDirectory = nil
            snapshotStamp = []
            return
        }
        let records = session.commandRecords.records(inDirectory: nil)
        let grid = session.snapshot()
        refresh(records: records, grid: grid, directory: session.workingDirectory)
    }

    func refresh(records: [CommandRecord], grid: Grid, directory: String?) {
        let stamp =
            [
                grid.linesGeneration, UInt64(grid.scrollback.totalPushed),
                UInt64(grid.scrollback.count),
            ]
            + (0..<grid.rows).map { grid.lineRevision($0) }
        if currentDirectory != directory { currentDirectory = directory }
        guard records != cachedRecords || stamp != snapshotStamp else { return }
        cachedRecords = records
        snapshotStamp = stamp
        cachedRows = records.map { Self.row(for: $0, grid: grid) }
        knownHosts = Set(records.compactMap(\.host)).sorted()
    }

    var projectLookupPaths: [String] {
        guard projectOnly else { return [] }
        return Set(
            cachedRecords.compactMap(\.workingDirectory)
                + [currentDirectory].compactMap { $0 }
        ).sorted()
    }

    /// Runs once per distinct set of directories; cancellation prevents stale publication.
    func resolveProjectRoots() async {
        let paths = projectLookupPaths
        let roots = await Self.lookupProjectRoots(paths, resolve: projectRoot)
        guard !Task.isCancelled, paths == projectLookupPaths else { return }
        projectRoots = roots
    }

    @concurrent
    private static func lookupProjectRoots(
        _ paths: [String], resolve: @Sendable (String) -> String?
    ) async -> [String: String] {
        var roots: [String: String] = [:]
        for path in paths {
            guard !Task.isCancelled else { break }
            roots[path] = resolve(path)
        }
        return roots
    }

    var rows: [Row] {
        let root = currentDirectory.flatMap { projectRoots[$0] }
        let selected = zip(cachedRecords, cachedRows).compactMap { record, row -> Row? in
            if directoryOnly, let currentDirectory,
                record.workingDirectory != currentDirectory
            {
                return nil
            }
            switch hostScope {
            case .any: break
            case .local: if record.host != nil { return nil }
            case .host(let name): if record.host != name { return nil }
            }
            if projectOnly, let root,
                record.workingDirectory.flatMap({ projectRoots[$0] }) != root
            {
                return nil
            }
            switch exitFilter {
            case .any: break
            case .succeeded: if record.exitStatus != 0 { return nil }
            case .failed: if !record.didFail { return nil }
            }
            return row
        }
        return Self.filter(selected, query: query)
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
            directoryText =
                record.workingDirectory.map { ($0 as NSString).lastPathComponent }
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
        refresh()
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
