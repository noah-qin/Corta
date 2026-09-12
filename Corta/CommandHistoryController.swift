import AppKit
import CortaTerminal

/// B08 — search command records by directory, project and exit status;
/// separate find/fill/run actions. `host` stays out of scope, the same
/// reason `CommandRecordStore.records(inDirectory:...)`'s own doc comment
/// gives: nothing carries one yet, and a real one waits for B13's SSH work.
///
/// A single shared window, re-targeted at whichever pane opened it —
/// `ShortcutsWindowController`'s pattern, not a fresh window per pane, since
/// only one can be meaningfully in front at a time and the history it shows
/// is only ever "this pane's".
@MainActor
final class CommandHistoryController: NSWindowController {
    static let shared = CommandHistoryController()

    private enum ExitFilter: Int {
        case any, succeeded, failed
    }

    private weak var pane: ViewController?
    private let resultsStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let directoryCheckbox = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private let projectCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let exitPopUp = NSPopUpButton()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("commandHistory.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        window.contentView = buildContentView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(for pane: ViewController) {
        self.pane = pane
        rebuild()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        directoryCheckbox.title = L10n.text("commandHistory.thisDirectory")
        directoryCheckbox.target = self
        directoryCheckbox.action = #selector(filterChanged)
        projectCheckbox.title = L10n.text("commandHistory.thisProject")
        projectCheckbox.target = self
        projectCheckbox.action = #selector(filterChanged)

        exitPopUp.addItems(withTitles: [
            L10n.text("commandHistory.exitAny"),
            L10n.text("commandHistory.exitSucceeded"),
            L10n.text("commandHistory.exitFailed"),
        ])
        exitPopUp.target = self
        exitPopUp.action = #selector(filterChanged)

        let clearButton = NSButton(
            title: L10n.text("commandHistory.clear"), target: self,
            action: #selector(clearCommandHistory))

        let filterRow = NSStackView(views: [
            directoryCheckbox, projectCheckbox, exitPopUp, NSView(), clearButton,
        ])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 12

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = SystemAccessibility.secondaryLabelColor

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 4
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(resultsStack)
        NSLayoutConstraint.activate([
            resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        let root = NSStackView(views: [filterRow, countLabel, scrollView])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.setCustomSpacing(4, after: filterRow)
        root.translatesAutoresizingMaskIntoConstraints = false
        // The scroll view is the one row that should actually grow.
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }

    @objc private func filterChanged() { rebuild() }

    @objc private func clearCommandHistory() {
        pane?.session?.clearCommandRecords()
        rebuild()
    }

    // MARK: - Filtering and rows

    private func rebuild() {
        resultsStack.views.forEach { $0.removeFromSuperview() }
        guard let pane, let session = pane.session else {
            countLabel.stringValue = L10n.text("commandHistory.noPane")
            return
        }
        let grid = session.snapshot()
        let directory = directoryCheckbox.state == .on ? session.workingDirectory : nil
        var records = session.commandRecords.records(inDirectory: directory)
        if projectCheckbox.state == .on, let cwd = session.workingDirectory,
            let root = DirectoryHistory.projectRoot(for: cwd)
        {
            records = records.filter {
                $0.workingDirectory.flatMap { DirectoryHistory.projectRoot(for: $0) } == root
            }
        }
        switch ExitFilter(rawValue: exitPopUp.indexOfSelectedItem) ?? .any {
        case .any: break
        case .succeeded: records = records.filter { $0.exitStatus == 0 }
        case .failed: records = records.filter { $0.didFail }
        }
        countLabel.stringValue = L10n.format("commandHistory.count", records.count)
        for record in records {
            resultsStack.addView(row(for: record, grid: grid, pane: pane), in: .top)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func row(for record: CommandRecord, grid: Grid, pane: ViewController) -> NSView {
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
        let statusIcon = NSImageView(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: statusDescription)
                ?? NSImage())
        statusIcon.contentTintColor =
            SystemAccessibility.increaseContrast ? .labelColor : .secondaryLabelColor

        let time = NSTextField(
            labelWithString: Self.timestampFormatter.string(from: record.startedAt))
        time.font = .systemFont(ofSize: 12)
        time.setContentHuggingPriority(.required, for: .horizontal)

        let directoryText = record.workingDirectory.map { ($0 as NSString).lastPathComponent }
            ?? L10n.text("commandHistory.unknownDirectory")
        let directory = NSTextField(labelWithString: directoryText)
        directory.font = .systemFont(ofSize: 12)
        directory.textColor = SystemAccessibility.secondaryLabelColor
        directory.toolTip = record.workingDirectory
        directory.lineBreakMode = .byTruncatingMiddle

        let findButton = NSButton(
            title: L10n.text("commandHistory.find"), target: self,
            action: #selector(findSelected))
        findButton.tag = record.id

        let text = commandHistoryLineText(for: record, grid: grid, pane: pane)
        let fillButton = NSButton(
            title: L10n.text("commandHistory.fill"), target: self,
            action: #selector(fillSelected))
        fillButton.tag = record.id
        fillButton.isEnabled = text != nil
        let runButton = NSButton(
            title: L10n.text("commandHistory.run"), target: self, action: #selector(runSelected))
        runButton.tag = record.id
        runButton.isEnabled = text != nil

        let row = NSStackView(views: [
            statusIcon, time, directory, NSView(), findButton, fillButton, runButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(
            L10n.format(
                "commandHistory.a11yRow", statusDescription, time.stringValue, directoryText))
        return row
    }

    /// Kept as a free function of the row's own inputs rather than a
    /// property, so building 500 rows does not re-snapshot the grid once per
    /// row — `rebuild()` takes one snapshot and this reads from it.
    private func commandHistoryLineText(for record: CommandRecord, grid: Grid, pane: ViewController)
        -> String?
    {
        ViewController.commandLineText(grid: grid, record: record)
    }

    // MARK: - Row actions

    @objc private func findSelected(_ sender: NSButton) {
        guard let pane, pane.focusCommand(id: sender.tag) else { return }
        window?.close()
        pane.view.window?.makeKeyAndOrderFront(nil)
        pane.view.window?.makeFirstResponder(pane.terminalView)
    }

    @objc private func fillSelected(_ sender: NSButton) {
        guard let pane, let record = pane.session?.commandRecords.records.first(where: {
            $0.id == sender.tag
        }), let text = pane.commandLineText(for: record) else { return }
        guard pane.fillPrompt(with: text) else {
            pane.terminalView?.showToast(L10n.text("toast.cannotFillPrompt"), kind: .warning)
            return
        }
        window?.close()
    }

    @objc private func runSelected(_ sender: NSButton) {
        guard let pane, let record = pane.session?.commandRecords.records.first(where: {
            $0.id == sender.tag
        }), let text = pane.commandLineText(for: record) else { return }
        guard pane.fillAndRunPrompt(with: text) else {
            pane.terminalView?.showToast(L10n.text("toast.cannotFillPrompt"), kind: .warning)
            return
        }
        window?.close()
    }
}
