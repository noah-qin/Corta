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
    /// A group heading or a command. Headings are non-selectable and skipped
    /// by the arrow keys, so the list reads as sections without the selection
    /// ever landing on one.
    private enum Row {
        case header(String)
        case command(TerminalCommand)
    }

    private var rows: [Row] = []
    /// Shown in place of the list when a query matches nothing. A blank panel
    /// left the user unable to tell "no such command" from "the palette has
    /// stopped responding".
    private let emptyLabel = NSTextField(labelWithString: "")
    /// The commands run from the palette, most recent first, deduplicated.
    ///
    /// In memory and for this launch only — deliberately not a config-file
    /// key. The config file is the user's settings, and a most-recently-used
    /// list is neither a setting nor something anyone would hand-edit; a key
    /// for it would be a key `docs/CONFIGURATION.md` has to document and
    /// nobody would ever set.
    private var recentCommands: [TerminalCommand] = []
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
        searchField.placeholderString = L10n.text("commandPalette.placeholder")
        searchField.font = .systemFont(ofSize: 16)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // 26 pt put a 13 pt title and an 11 pt shortcut inside 26 points with
        // nothing left over; a long command and its shortcut had no air on
        // either side of them.
        tableView.rowHeight = Self.commandRowHeight
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

        emptyLabel.stringValue = L10n.text("commandPalette.empty")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = SystemAccessibility.secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let list = NSView()
        for subview in [scrollView, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            list.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: list.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: list.topAnchor, constant: 28),
        ])

        let stack = NSStackView(views: [searchField, NSBox.separator(), list])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        // M9: a floating control over content is exactly where Liquid
        // Glass belongs (`ViewController.swift`'s rationale for the search
        // bar, `:383-390` — the terminal canvas is content and stays
        // opaque; the palette is chrome, like the search bar). One surface,
        // so no `NSGlassEffectContainerView` merge to set up — that exists
        // for *neighbouring* glass elements, and the palette has none.
        let content = NSGlassEffectView()
        content.style = .regular
        // Reduce Transparency means background content must not show
        // through, so the glass gets an opaque tint rather than a lowered
        // alpha — same as the search bar — and the panel then needs a
        // drawn border, because the material edge that separated it from
        // the desktop is gone with it.
        if SystemAccessibility.reduceTransparency {
            content.tintColor = .windowBackgroundColor
        }
        if SystemAccessibility.increaseContrast || SystemAccessibility.reduceTransparency {
            content.wantsLayer = true
            let border = SystemAccessibility.panelBorder
            content.layer?.borderColor = border.color.cgColor
            content.layer?.borderWidth = border.width
        }
        let contentWrapper = NSView()
        contentWrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentWrapper.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentWrapper.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentWrapper.bottomAnchor),
        ])
        content.contentView = contentWrapper
        // The panel's own contentRect is fixed at construction (`init`,
        // `NSRect(x: 0, y: 0, width: 520, height: 360)`), unlike the search
        // bar's — which waits on live layout — so the radius is knowable
        // immediately. Matches the window-corner radius used elsewhere
        // (`TerminalView.swift`'s `metalLayer.cornerRadius = 10`) rather
        // than the search bar's full pill: a whole panel reads as a window,
        // not a control.
        content.cornerRadius = 10
        return content
    }

    // MARK: - Filtering

    /// Subsequence matching, which is what people mean by "fuzzy" here:
    /// `spr` finds "Split Pane Right". Ranked so that a match on consecutive
    /// characters, or one starting at a word boundary, beats a scattered one.
    private func reloadMatches() {
        let query = searchField.stringValue.lowercased()
        rows = query.isEmpty ? browsingRows() : searchRows(matching: query)
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        if let first = rows.firstIndex(where: { if case .command = $0 { true } else { false } }) {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
    }

    /// With no query: what was used recently, then every command under its
    /// group heading. Recents first because the single most likely next
    /// command is one of the last few — and it is the only ordering that gets
    /// shorter with use rather than longer.
    private func browsingRows() -> [Row] {
        var rows: [Row] = []
        let recents = recentCommands.prefix(Self.recentLimit)
        if !recents.isEmpty {
            rows.append(.header(L10n.text("commandPalette.category.recent")))
            rows.append(contentsOf: recents.map { Row.command($0) })
        }
        for category in CommandCategory.allCases {
            let commands = TerminalCommand.allCases
                .filter { $0.category == category }
                .sorted { $0.paletteRank < $1.paletteRank }
            guard !commands.isEmpty else { continue }
            rows.append(.header(category.title))
            rows.append(contentsOf: commands.map { Row.command($0) })
        }
        return rows
    }

    /// With a query: one flat ranked list, no headings. A search result is
    /// already ordered by how well it matched, and grouping would fight that
    /// ordering for the sake of a structure the user has stopped browsing.
    private func searchRows(matching query: String) -> [Row] {
        TerminalCommand.allCases
            .compactMap { command -> (TerminalCommand, Int)? in
                guard let score = Self.score(command.title.lowercased(), query: query)
                else { return nil }
                // A recently used command wins a tie against one that has
                // never been run, which is the same argument as the recents
                // section, applied inside the ranking.
                let recency =
                    recentCommands.firstIndex(of: command)
                    .map { Self.recentLimit - $0 } ?? 0
                return (command, score + recency)
            }
            .sorted { $0.1 > $1.1 }
            .map { Row.command($0.0) }
    }

    private static let recentLimit = 5
    static let commandRowHeight: CGFloat = 32
    static let headerRowHeight: CGFloat = 26

    private func command(at row: Int) -> TerminalCommand? {
        guard row >= 0, row < rows.count, case .command(let command) = rows[row]
        else { return nil }
        return command
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
        guard let command = command(at: tableView.selectedRow) else { return }
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
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

    /// Steps to the next *command* row, stepping over headings rather than
    /// selecting them — a heading is a label, and an arrow key that lands on
    /// one leaves Return with nothing to run.
    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        var row = tableView.selectedRow
        var remaining = abs(delta)
        let step = delta > 0 ? 1 : -1
        while remaining > 0 {
            var next = row + step
            while next >= 0, next < rows.count, command(at: next) == nil { next += step }
            guard next >= 0, next < rows.count else { break }
            row = next
            remaining -= 1
        }
        guard command(at: row) != nil else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // The heading above a section scrolls into view with its first
        // command, so a jump to a new group shows which group it is.
        let anchor = row > 0 && command(at: row - 1) == nil ? row - 1 : row
        tableView.scrollRowToVisible(anchor)
    }
}

extension CommandPaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reloadMatches()
    }
}

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        command(at: row) == nil ? Self.headerRowHeight : Self.commandRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        command(at: row) == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        command(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = SystemAccessibility.secondaryLabelColor
            label.setAccessibilityRole(.staticText)
            return label
        case .command(let command):
            let title = NSTextField(labelWithString: command.title)
            title.font = .systemFont(ofSize: 13)
            let shortcut = NSTextField(
                labelWithString: ConfigurationStore.shared.configuration.keybindings[command]?
                    .displayText ?? "")
            shortcut.textColor = SystemAccessibility.secondaryLabelColor
            shortcut.alignment = .right
            // The system font, not a monospaced one: these are the same
            // ⌘⇧D / ← / ⇞ glyphs the menu bar draws, and the menu bar draws
            // them in the system face.
            shortcut.font = .systemFont(ofSize: 12)
            shortcut.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [title, NSView(), shortcut])
            stack.orientation = .horizontal
            stack.distribution = .fill
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
            // One element with one name, so VoiceOver announces "Split Pane
            // Right, Command Shift D" instead of two adjacent labels.
            stack.setAccessibilityRole(.staticText)
            stack.setAccessibilityLabel(
                shortcut.stringValue.isEmpty
                    ? command.title : "\(command.title), \(shortcut.stringValue)")
            return stack
        }
    }
}

extension NSBox {
    fileprivate static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
