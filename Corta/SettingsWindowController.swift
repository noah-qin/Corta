import AppKit

/// M6.1 — the settings page.
///
/// **Shape.** A toolbar of tabs over one short pane, the way macOS's own
/// preference windows are built: `NSWindow.toolbarStyle = .preference`, a
/// selectable toolbar item per tab, and a window that resizes to the height
/// of whichever tab is showing.
///
/// It got here by way of two versions that were too big. A flat grid of a
/// dozen controls read as a wall of widgets; giving the groups cards and a
/// line of explanation each made every group legible and the *window*
/// enormous — 534×819, most of it scrolled out of sight, for eleven settings.
/// Tabs keep both: three panes of four or five rows, none of which scrolls,
/// in a window a little over three hundred points tall.
///
/// **Rules the layout follows.**
/// - Every row is a right-aligned label in a fixed column and a control in a
///   fixed value column, so the whole page shares one vertical line. Nothing
///   is sized by its own intrinsic width.
/// - Explanations are rare and short. A control that needs a paragraph is
///   usually a control that needs a better label; the few that carry a real
///   consequence keep one line each, and the rest carry a tooltip or nothing.
/// - Rows are built from explicit constraints inside a plain container. Two
///   columns, one of which stacks a control over a wrapping label, is more
///   than a stack view's single alignment axis can express — and a container
///   that positions its content by an implicit rule (an `NSBox` and its
///   autoresized `contentView`, say) is what turned this page into a pile of
///   overlapping rows once already.
///
/// Every control writes through `ConfigurationStore.update`, which writes
/// the file and re-reads it. Nothing here holds state of its own — the page
/// re-populates from the store on `ConfigurationStore.didChange`, so an edit
/// made in `$EDITOR` while this window is open moves the controls, and the
/// two directions cannot disagree.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    /// One tab. The order here is the toolbar's order, and it runs from what
    /// a user changes often to what they change once.
    private enum Tab: String, CaseIterable {
        case appearance
        case terminal
        case general

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .terminal: return "Terminal"
            case .general: return "General"
            }
        }

        /// SF Symbols, so the toolbar matches every other preference window
        /// on the system and follows the user's icon weight.
        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .terminal: return "terminal"
            case .general: return "gearshape"
            }
        }

        var identifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("dev.noahqin.Corta.settings.\(rawValue)")
        }
    }

    /// The page's geometry, in one place: a right-aligned label column, a
    /// gap, and a value column every control and every explanation starts at.
    private static let labelColumnWidth: CGFloat = 132
    private static let columnGap: CGFloat = 10
    private static let valueColumnWidth: CGFloat = 218
    /// The margin from the window's edge to a row.
    private static let pageMargin: CGFloat = 22
    /// Vertical space between rows.
    private static let rowSpacing: CGFloat = 14
    /// Derived, so a change to a column cannot leave the window too narrow
    /// for its own rows.
    private static let contentWidth: CGFloat =
        2 * pageMargin + labelColumnWidth + columnGap + valueColumnWidth

    private let themePopUp = NSPopUpButton()
    private let appearancePopUp = NSPopUpButton()
    private let fontFamilyLabel = NSTextField(labelWithString: "")
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let scrollbackField = NSTextField()
    private let columnsField = NSTextField()
    private let rowsField = NSTextField()
    private let bellPopUp = NSPopUpButton()
    private let copyOnSelectSwitch = NSSwitch()
    private let linkActivationPopUp = NSPopUpButton()
    private let clipboardWriteSwitch = NSSwitch()
    private let restoreWindowsSwitch = NSSwitch()
    private let confirmCloseSwitch = NSSwitch()
    private let notifySwitch = NSSwitch()
    private let thresholdField = NSTextField()
    private let thresholdLabel = NSTextField(labelWithString: "Longer than")
    private let pathLabel = NSTextField(labelWithString: "")

    /// The panes, built on first visit and kept. A control on a tab that is
    /// not showing is still populated from the store, so switching tabs never
    /// shows a stale value and never needs a rebuild.
    private var panes: [Tab: NSView] = [:]
    private var currentTab: Tab = .appearance
    /// Where a pane is swapped in.
    private let paneContainer = NSView()
    private var paneConstraints: [NSLayoutConstraint] = []

    /// The theme row, hidden entirely while there is only one theme to pick
    /// from — a pop-up with a single item is a control that cannot be used,
    /// and showing one is worse than showing nothing. It comes back the
    /// moment the config file defines a theme (M7.6).
    private var themeRow: NSView?
    /// The themes the pop-up currently lists, in its own order.
    private var listedThemes: [Theme] = []
    /// Suppresses the write-back while the page is being populated from the
    /// store — otherwise setting a control's value looks like a user edit
    /// and writes the file back at itself.
    private var isPopulating = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
            // Not resizable: every pane is laid out for one width and sized
            // to its own content, so there is nothing for a drag to do.
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContentView()
        installToolbar()
        NotificationCenter.default.addObserver(
            self, selector: #selector(populate), name: ConfigurationStore.didChange, object: nil)
        populate()
        show(tab: currentTab, animated: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        // The file may not exist until something writes it; writing on first
        // open is what makes the format discoverable and gives "Reveal"
        // something to reveal.
        ConfigurationStore.shared.write()
        populate()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Tabs

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "dev.noahqin.Corta.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = currentTab.identifier
        window?.toolbar = toolbar
        // The style that puts the tabs where a preference window's tabs go:
        // centred under the title bar, with the title itself suppressed.
        window?.toolbarStyle = .preference
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = Tab.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = Tab.allCases.first(where: { $0.identifier == sender.itemIdentifier })
        else { return }
        show(tab: tab, animated: true)
    }

    /// Swaps the pane in and resizes the window to it, keeping the title bar
    /// where it is: a preference window that grows downwards reads as one
    /// window changing, and one that grows from its centre reads as a jump.
    private func show(tab: Tab, animated: Bool) {
        guard let window else { return }
        currentTab = tab
        // Suppressed by `.preference` toolbar style, but it is what Mission
        // Control and the Window menu show.
        window.title = "Corta Settings"
        window.toolbar?.selectedItemIdentifier = tab.identifier

        let pane = self.pane(for: tab)
        NSLayoutConstraint.deactivate(paneConstraints)
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        paneContainer.addSubview(pane)
        paneConstraints = [
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(lessThanOrEqualTo: paneContainer.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(paneConstraints)
        resizeToFitPane(animated: animated)
    }

    private func resizeToFitPane(animated: Bool) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let frame = window.frameRect(
            forContentRect: NSRect(
                x: 0, y: 0, width: Self.contentWidth, height: content.fittingSize.height))
        var target = window.frame
        // Top-left pinned: only the bottom edge moves.
        target.origin.y += target.height - frame.height
        target.size = frame.size
        window.setFrame(target, display: true, animate: animated)
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        configureControls()

        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        let footer = buildFooter()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for subview in [paneContainer, separator, footer] { content.addSubview(subview) }
        NSLayoutConstraint.activate([
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            paneContainer.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.pageMargin),
            paneContainer.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.pageMargin),

            separator.topAnchor.constraint(
                equalTo: paneContainer.bottomAnchor, constant: Self.pageMargin),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 9),
            footer.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.pageMargin),
            footer.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.pageMargin),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -11),
        ])
        return content
    }

    /// One line under a hairline: where the settings live, and a way to get
    /// there. Small, grey and last, because it answers a question only some
    /// users ask — but it is what makes the config file discoverable at all.
    private func buildFooter() -> NSView {
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = "Every setting on this page is stored in this file."
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(title: "Reveal", target: self, action: #selector(revealConfigFile))
        reveal.bezelStyle = .accessoryBarAction
        reveal.controlSize = .small
        reveal.setContentHuggingPriority(.required, for: .horizontal)
        reveal.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = NSStackView(views: [pathLabel, reveal])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    /// A tab's rows, built once.
    private func pane(for tab: Tab) -> NSView {
        if let existing = panes[tab] { return existing }
        let rows: [NSView]
        switch tab {
        case .appearance:
            let themeRow = row("Theme", themePopUp)
            self.themeRow = themeRow
            rows = [
                themeRow,
                row("Light or dark", appearancePopUp),
                row("Font", fontFamilyLabel),
                row("Size", makeFontSizeRow()),
            ]
        case .terminal:
            rows = [
                row(
                    "Scrollback", scrollbackField,
                    help: "Lines kept per session; applies to new sessions."),
                row("Bell", bellPopUp),
                row("Copy on select", copyOnSelectSwitch),
                row("Open links with", linkActivationPopUp),
                row(
                    "Allow OSC 52 copy", clipboardWriteSwitch,
                    help: "Lets a program put text on the clipboard. Reading is never allowed."),
            ]
        case .general:
            rows = [
                row(
                    "New window", makeWindowSizeRow(),
                    help: "Columns × rows. The window's pixel size follows the font."),
                row("Restore windows", restoreWindowsSwitch),
                row(
                    "Confirm close", confirmCloseSwitch,
                    help: "Ask when a pane still has something running."),
                row(
                    "Notify on long tasks", notifySwitch,
                    help: "Only while the window is in the background."),
                row(thresholdLabel, makeThresholdRow()),
            ]
        }
        let pane = stack(rows)
        panes[tab] = pane
        return pane
    }

    /// Rows in a column. A stack view earns its place here for one reason:
    /// the theme row is hidden while there is a single theme, and collapsing
    /// a hidden arranged subview is the one thing a chain of constraints
    /// would have to be rebuilt to do.
    private func stack(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Rows

    private func row(_ title: String, _ control: NSView, help: String? = nil) -> NSView {
        row(label(title), control, help: help)
    }

    /// One form row: a right-aligned label, the control in the shared value
    /// column, and an optional line of grey explanation under it.
    private func row(_ title: NSTextField, _ control: NSView, help: String? = nil) -> NSView {
        title.alignment = .right
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        var constraints: [NSLayoutConstraint] = [
            container.widthAnchor.constraint(
                equalToConstant: Self.labelColumnWidth + Self.columnGap + Self.valueColumnWidth),

            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth),
            // Against the control's centre — the only alignment that reads
            // right across a pop-up, a switch and a text field at once.
            title.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            title.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),

            control.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Self.labelColumnWidth + Self.columnGap),
            control.topAnchor.constraint(equalTo: container.topAnchor),
        ]

        if let help {
            let note = NSTextField(wrappingLabelWithString: help)
            note.font = .systemFont(ofSize: 10)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            // The wrap width is stated twice on purpose: once as the
            // constraint that sizes the field, once as the width Cocoa
            // measures its height against. Without the second it reports the
            // height of one line and the rows below it overlap.
            note.preferredMaxLayoutWidth = Self.valueColumnWidth
            container.addSubview(note)
            constraints += [
                note.leadingAnchor.constraint(equalTo: control.leadingAnchor),
                note.topAnchor.constraint(equalTo: control.bottomAnchor, constant: 3),
                note.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth),
                note.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
        } else {
            constraints.append(control.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        }

        // A pop-up sizes itself to its longest item, which puts every pop-up
        // on the page at a different width; a text field has no intrinsic
        // width worth having. Both are pinned to the value column instead.
        if control is NSPopUpButton {
            constraints.append(
                control.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth))
        }
        if control === scrollbackField {
            constraints.append(control.widthAnchor.constraint(equalToConstant: 92))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func makeFontSizeRow() -> NSView {
        fontSizeField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let stack = NSStackView(views: [fontSizeField, fontSizeStepper])
        stack.spacing = 4
        stack.alignment = .centerY
        return stack
    }

    /// `120 × 30`: the grid a new window opens with, in cells. Two fields
    /// rather than one, because a single "1200x300" string would need its own
    /// parser and its own error state for a value the user types by hand.
    private func makeWindowSizeRow() -> NSView {
        for field in [columnsField, rowsField] {
            field.alignment = .right
            field.target = self
            field.action = #selector(commit)
            field.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [columnsField, times, rowsField])
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    private func makeThresholdRow() -> NSView {
        thresholdField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let suffix = NSTextField(labelWithString: "seconds")
        suffix.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [thresholdField, suffix])
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    // MARK: - Controls

    private func configureControls() {
        themePopUp.target = self
        themePopUp.action = #selector(commit)

        for appearance in Configuration.Appearance.allCases {
            let title = appearance == .auto ? "Follow System" : appearance.rawValue.capitalized
            appearancePopUp.addItem(withTitle: title)
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(commit)

        // The font family is stated, not chosen. Corta ships one font — the
        // system monospaced face, the one face guaranteed to be present, to
        // be hinted for this display, and to carry what a terminal needs. The
        // picker that used to be here listed every installed family that
        // passed `MonospacedFontCatalog`, and that check answers "will this
        // render on a grid", not "is this worth reading for eight hours": the
        // list's quality was whatever the user happened to have installed.
        // `font-family` in the config file still works and is still verified;
        // what is gone is Corta *recommending* a hundred faces it knows
        // nothing about.
        fontFamilyLabel.toolTip =
            "Corta uses the system monospaced font. Set `font-family` in the config file to use "
            + "another; families whose glyphs do not all advance by one cell are rejected."

        fontSizeField.alignment = .right
        fontSizeField.target = self
        fontSizeField.action = #selector(commit)
        fontSizeStepper.minValue = 8
        fontSizeStepper.maxValue = 64
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(stepFontSize)

        scrollbackField.alignment = .right
        scrollbackField.target = self
        scrollbackField.action = #selector(commit)

        // Selected by position rather than matched by title: the mode used to
        // be recovered with `BellMode(rawValue: title.lowercased())`, which
        // worked only while every display name was its raw value capitalised.
        // Renaming one item would have silently reset the setting to Visual.
        for mode in Self.bellModes { bellPopUp.addItem(withTitle: mode.displayName) }
        bellPopUp.target = self
        bellPopUp.action = #selector(commit)

        linkActivationPopUp.addItem(withTitle: "Command-click")
        linkActivationPopUp.addItem(withTitle: "Click")
        linkActivationPopUp.target = self
        linkActivationPopUp.action = #selector(commit)

        for control in [
            copyOnSelectSwitch, clipboardWriteSwitch, restoreWindowsSwitch, confirmCloseSwitch,
            notifySwitch,
        ] {
            control.target = self
            control.action = #selector(commit)
        }
        thresholdField.alignment = .right
        thresholdField.target = self
        thresholdField.action = #selector(commit)
    }

    /// The bell modes in the order the pop-up lists them; the index is the
    /// value.
    private static let bellModes: [BellMode] = [.visual, .audible, .muted]

    // MARK: - Store <-> controls

    @objc private func populate() {
        isPopulating = true
        defer { isPopulating = false }
        let configuration = ConfigurationStore.shared.configuration

        // Rebuilt every time: the config file can define, rename or remove a
        // theme while this window is open.
        listedThemes = Theme.all(in: configuration)
        themePopUp.removeAllItems()
        for theme in listedThemes { themePopUp.addItem(withTitle: theme.displayName) }
        if let index = listedThemes.firstIndex(where: { $0.name == configuration.theme }) {
            themePopUp.selectItem(at: index)
        }
        let hideTheme = listedThemes.count < 2
        if let themeRow, themeRow.isHidden != hideTheme {
            themeRow.isHidden = hideTheme
            // The showing pane just got a row shorter or taller.
            if currentTab == .appearance { resizeToFitPane(animated: false) }
        }

        if let index = Configuration.Appearance.allCases.firstIndex(of: configuration.appearance) {
            appearancePopUp.selectItem(at: index)
        }
        // The family the config file names, or the sentinel spelled out. Not
        // `NSFont.monospacedSystemFont(...).familyName`, which is the
        // internal `.AppleSystemUIFontMonospaced` — a name that answers no
        // question a reader of this page has.
        fontFamilyLabel.stringValue =
            configuration.fontFamily == Configuration.systemFontFamily
            ? "System Monospaced" : configuration.fontFamily
        fontSizeField.stringValue = String(Int(configuration.fontSize))
        fontSizeStepper.doubleValue = configuration.fontSize
        scrollbackField.stringValue = String(configuration.scrollbackLines)
        columnsField.stringValue = String(configuration.columns)
        rowsField.stringValue = String(configuration.rows)
        bellPopUp.selectItem(at: Self.bellModes.firstIndex(of: configuration.bell) ?? 0)
        copyOnSelectSwitch.state = configuration.copyOnSelect ? .on : .off
        linkActivationPopUp.selectItem(at: configuration.linkActivation == .click ? 1 : 0)
        clipboardWriteSwitch.state = configuration.allowClipboardWrite ? .on : .off
        restoreWindowsSwitch.state = configuration.restoreWindows ? .on : .off
        confirmCloseSwitch.state = configuration.confirmClose ? .on : .off
        notifySwitch.state = configuration.notifyOnLongTask ? .on : .off
        thresholdField.stringValue = String(Int(configuration.notificationThreshold))
        // The threshold only means anything while notifications are on. An
        // editable field that changes nothing is a setting that looks broken.
        thresholdField.isEnabled = configuration.notifyOnLongTask
        thresholdLabel.textColor =
            configuration.notifyOnLongTask ? .labelColor : .disabledControlTextColor
        pathLabel.stringValue = ConfigurationStore.fileURL.path
    }

    @objc private func stepFontSize() {
        fontSizeField.stringValue = String(Int(fontSizeStepper.doubleValue))
        commit()
    }

    /// One handler for every control: read the whole page, write the whole
    /// file. Per-control write-backs would need per-control validation and
    /// would still round-trip through the same file.
    @objc private func commit() {
        guard !isPopulating else { return }
        let themeIndex = max(0, themePopUp.indexOfSelectedItem)
        let appearanceIndex = max(0, appearancePopUp.indexOfSelectedItem)
        let bellIndex = max(0, bellPopUp.indexOfSelectedItem)
        ConfigurationStore.shared.update { configuration in
            if themeIndex < listedThemes.count {
                configuration.theme = listedThemes[themeIndex].name
            }
            configuration.appearance = Configuration.Appearance.allCases[appearanceIndex]
            if let size = Double(fontSizeField.stringValue) {
                configuration.fontSize = min(64, max(8, size))
            }
            if let lines = Int(scrollbackField.stringValue) {
                configuration.scrollbackLines = min(1_000_000, max(0, lines))
            }
            if let columns = Int(columnsField.stringValue) {
                configuration.columns = min(500, max(20, columns))
            }
            if let rows = Int(rowsField.stringValue) {
                configuration.rows = min(300, max(5, rows))
            }
            if bellIndex < Self.bellModes.count { configuration.bell = Self.bellModes[bellIndex] }
            configuration.copyOnSelect = copyOnSelectSwitch.state == .on
            configuration.linkActivation =
                linkActivationPopUp.indexOfSelectedItem == 1 ? .click : .command
            configuration.allowClipboardWrite = clipboardWriteSwitch.state == .on
            configuration.restoreWindows = restoreWindowsSwitch.state == .on
            configuration.confirmClose = confirmCloseSwitch.state == .on
            configuration.notifyOnLongTask = notifySwitch.state == .on
            if let seconds = Double(thresholdField.stringValue) {
                configuration.notificationThreshold = max(1, seconds)
            }
        }
        // A clamped or rejected value has to appear in the field, or the
        // page shows something the file does not say.
        populate()
    }

    @objc private func revealConfigFile() {
        ConfigurationStore.shared.write()
        NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.fileURL])
    }
}
