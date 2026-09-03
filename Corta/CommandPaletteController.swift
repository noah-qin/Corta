import AppKit

/// M7.12 — the command palette.
///
/// Corta reached about thirty commands spread across five menus, a context
/// menu and a settings page, and the only way to find one was to already know
/// which menu it was under. A palette is the cheap fix: type part of a name,
/// press Return. It costs nothing to maintain because it does not own a list
/// — it renders `TerminalCommand.allCases`, the same table the menus and the
/// keybindings read, so a command added there appears here for free.
///
/// Dispatch goes through `NSApp.sendAction(_:to:from:)` with a `nil` target,
/// which is the responder chain — exactly what a menu item does. That is what
/// makes "Split Pane Right" from the palette land on the right window's split
/// controller without the palette knowing any of them exist. The panel is
/// closed *before* the action is sent, because while it is key the chain
/// starts at the palette and every terminal command would find no handler.
@MainActor
final class CommandPaletteController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteController()

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private var matches: [TerminalCommand] = []
    private var keyMonitor: Any?
    /// The window the palette was opened over. Commands act on the key
    /// window, and the palette itself becomes key while it is up.
    private weak var invokingWindow: NSWindow?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = buildContentView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presenting

    @objc func show(_ sender: Any?) {
        guard let window else { return }
        invokingWindow = NSApp.keyWindow
        searchField.stringValue = ""
        reloadMatches()
        if let host = invokingWindow {
            // Centred over the window it was invoked from, a third of the way
            // down — where a palette is looked for, and clear of the prompt.
            let frame = window.frame
            window.setFrameOrigin(
                NSPoint(
                    x: host.frame.midX - frame.width / 2,
                    y: host.frame.maxY - frame.height - host.frame.height / 6))
        } else {
            window.center()
        }
        showWindow(sender)
        window.makeKeyAndOrderFront(sender)
        window.makeFirstResponder(searchField)
        installKeyMonitor()
    }

    func close(runningNothing: Bool = true) {
        removeKeyMonitor()
        window?.orderOut(nil)
        invokingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away dismisses, like every other palette.
        close()
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        searchField.placeholderString = "Command"
        searchField.font = .systemFont(ofSize: 16)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(runSelected)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [searchField, NSBox.separator(), scrollView])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    // MARK: - Filtering

    /// Subsequence matching, which is what people mean by "fuzzy" here:
    /// `spr` finds "Split Pane Right". Ranked so that a match on consecutive
    /// characters, or one starting at a word boundary, beats a scattered one.
    private func reloadMatches() {
        let query = searchField.stringValue.lowercased()
        let commands = TerminalCommand.allCases
        if query.isEmpty {
            matches = commands
        } else {
            matches =
                commands
                .compactMap { command -> (TerminalCommand, Int)? in
                    guard let score = Self.score(command.title.lowercased(), query: query)
                    else { return nil }
                    return (command, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        tableView.reloadData()
        if !matches.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Pure, and deliberately not `@MainActor`: the ranking is the part worth
    /// testing, and a scoring function that needs a window to run is one
    /// nobody tests.
    nonisolated static func score(_ candidate: String, query: String) -> Int? {
        var score = 0
        var previousIndex: Int?
        var searchIndex = candidate.startIndex
        let characters = Array(candidate)
        for character in query {
            guard let found = candidate[searchIndex...].firstIndex(of: character) else {
                return nil
            }
            let offset = candidate.distance(from: candidate.startIndex, to: found)
            // Adjacent to the previous match, or at the start of a word:
            // both are what a person is picturing when they type an
            // abbreviation.
            if previousIndex == offset - 1 { score += 3 }
            if offset == 0 || characters[offset - 1] == " " { score += 2 }
            previousIndex = offset
            searchIndex = candidate.index(after: found)
        }
        // Shorter titles win ties: "Copy" should beat "Copy on Select".
        return score * 100 - candidate.count
    }

    // MARK: - Running

    @objc private func runSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < matches.count else { return }
        let command = matches[row]
        close()
        // After the palette is gone and the terminal window is key again, so
        // the responder chain is the one the command expects.
        DispatchQueue.main.async {
            NSApp.sendAction(command.action, to: nil, from: nil)
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event -> NSEvent? in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53:  // Escape
                self.close()
                return nil
            case 36, 76:  // Return, keypad Enter
                self.runSelected()
                return nil
            case 125:  // Down
                self.moveSelection(by: 1)
                return nil
            case 126:  // Up
                self.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let row = min(max(0, tableView.selectedRow + delta), matches.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

extension CommandPaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reloadMatches()
    }
}

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row < matches.count else { return nil }
        let command = matches[row]
        let title = NSTextField(labelWithString: command.title)
        let shortcut = NSTextField(
            labelWithString: ConfigurationStore.shared.configuration.keybindings[command]?
                .displayText ?? "")
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [title, NSView(), shortcut])
        stack.orientation = .horizontal
        stack.distribution = .fill
        return stack
    }
}

extension NSBox {
    fileprivate static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
