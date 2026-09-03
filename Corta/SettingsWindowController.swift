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
            case .appearance: return L10n.text("settings.tab.appearance")
            case .terminal: return L10n.text("settings.tab.terminal")
            case .general: return L10n.text("settings.tab.general")
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

    /// The page's geometry: a right-aligned label column, a gap, and a value
    /// column every control and every explanation starts at.
    private static let columnGap: CGFloat = 10
    private static let valueColumnWidth: CGFloat = 218
    /// The margin from the window's edge to a row.
    private static let pageMargin: CGFloat = 22
    /// Vertical space between rows.
    private static let rowSpacing: CGFloat = 14
    /// How far a dependent row is indented under the setting it belongs to.
    private static let dependentIndent: CGFloat = 18

    /// Measured at launch, not fixed at 132.
    ///
    /// A constant fitted the English labels at the default system font size,
    /// and nothing else: "Benachrichtigungen bei langen Aufgaben" is half
    /// again as wide, and every label on the page grows with Larger Text in
    /// System Settings. Measuring the actual labels in the actual language at
    /// the actual size is the only version of this that cannot clip — and it
    /// costs one pass over fifteen strings, once.
    private let labelColumnWidth: CGFloat
    /// Derived, so a change to a column cannot leave the window too narrow
    /// for its own rows. The *minimum* width now: the window is resizable and
    /// the value column takes anything past this.
    private let contentWidth: CGFloat

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
    private let thresholdLabel = NSTextField(labelWithString: L10n.text("settings.label.longerThan"))
    private let pathLabel = NSTextField(labelWithString: "")
    /// The row under the notify switch, disabled and dimmed with it — held so
    /// the dependency can be expressed by the whole row rather than by the
    /// field alone.
    private var thresholdRow: NSView?
    private var notificationPermissionRow: NSView?
    /// Save feedback (icon, word and colour, in that order of importance —
    /// `SettingsStatusView`). Every control on this page writes immediately,
    /// which left the user with no way to tell a saved change from a silently
    /// clamped one from a write that failed outright.
    private let statusView = SettingsStatusView()
    /// Shown under the notification switch when macOS has been told not to
    /// deliver anything — an "on" switch over a denied permission is a
    /// setting that lies. Icon and words, with a button to the one place the
    /// decision can be reversed.
    private let notificationPermissionNotice = SettingsStatusView()

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
    /// Every explanation line on the page, so Increase Contrast can promote
    /// them all at once.
    private var helpNotes: [NSTextField] = []

    private init() {
        let labelColumn = Self.measuredLabelColumnWidth()
        labelColumnWidth = labelColumn
        contentWidth = 2 * Self.pageMargin + labelColumn + Self.columnGap + Self.valueColumnWidth
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 200),
            // Resizable, with the fitted size as the minimum. The panes were
            // laid out for exactly one width, which made the window unable to
            // give a long localized label or a Larger Text label any more
            // room than the English default happened to need; the value
            // column now takes whatever a drag adds.
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContentView()
        installToolbar()
        NotificationCenter.default.addObserver(
            self, selector: #selector(populate), name: ConfigurationStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationWriteStatusChanged),
            name: ConfigurationStore.writeStatusDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyNotificationPermission),
            name: TaskNotifier.permissionDidChange, object: nil)
        accessibilityObserver = SystemAccessibility.observe { [weak self] in
            self?.applySystemAccessibilityPreferences()
        }
        populate()
        show(tab: currentTab, animated: false)
        window.center()
    }

    /// The widest label the page will draw, in the running language and at
    /// the user's system font size, clamped so neither a terse language nor a
    /// runaway translation decides the whole window's proportions.
    private static func measuredLabelColumnWidth() -> CGFloat {
        let keys = [
            "settings.label.theme", "settings.label.lightOrDark", "settings.label.font",
            "settings.label.size", "settings.label.scrollback", "settings.label.bell",
            "settings.label.copyOnSelect", "settings.label.openLinksWith",
            "settings.label.allowClipboardCopy", "settings.label.newWindow",
            "settings.label.restoreWindows", "settings.label.confirmClose",
            "settings.label.notifyOnLongTasks", "settings.label.longerThan",
        ]
        let field = NSTextField(labelWithString: "")
        var widest: CGFloat = 0
        for key in keys {
            field.stringValue = L10n.text(key)
            // Two lines are allowed in a row, so a label may wrap rather than
            // widen the column past what a settings window should be.
            widest = max(widest, field.fittingSize.width)
        }
        return min(240, max(120, widest.rounded(.up)))
    }

    /// Retains the display-preferences observer for the window's lifetime.
    private var accessibilityObserver: Any?

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        // The file may not exist until something writes it; writing on first
        // open is what makes the format discoverable and gives "Show in
        // Finder" something to show.
        if !ConfigurationStore.shared.write() { showWriteFailure() }
        // System Settings can have flipped it since this window was last
        // open, so it is read on every open rather than cached.
        TaskNotifier.refreshPermission()
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
        window.title = L10n.text("settings.title")
        window.toolbar?.selectedItemIdentifier = tab.identifier

        let pane = self.pane(for: tab)
        NSLayoutConstraint.deactivate(paneConstraints)
        paneContainer.subviews.forEach { $0.removeFromSuperview() }
        paneContainer.addSubview(pane)
        paneConstraints = [
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(paneConstraints)
        resizeToFitPane(animated: animated)
    }

    private func resizeToFitPane(animated: Bool) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        // The user's own width is kept — the height is the only dimension a
        // tab switch has an opinion about.
        let width = max(contentWidth, content.frame.width)
        let frame = window.frameRect(
            forContentRect: NSRect(
                x: 0, y: 0, width: width, height: content.fittingSize.height))
        window.contentMinSize = NSSize(width: contentWidth, height: content.fittingSize.height)
        var target = window.frame
        // Top-left pinned: only the bottom edge moves.
        target.origin.y += target.height - frame.height
        target.size = frame.size
        // A resize the user did not ask for is exactly the motion Reduce
        // Motion is about: the window still lands in the same place, it just
        // gets there in one step.
        window.setFrame(target, display: true, animate: animated && !SystemAccessibility.reduceMotion)
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
        for subview in [paneContainer, statusView, separator, footer] {
            content.addSubview(subview)
        }
        statusView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(
                equalTo: paneContainer.bottomAnchor, constant: 10),
            statusView.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.pageMargin),
            statusView.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Self.pageMargin),

            paneContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            paneContainer.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.pageMargin),
            paneContainer.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.pageMargin),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: contentWidth),

            separator.topAnchor.constraint(
                equalTo: statusView.bottomAnchor, constant: 10),
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
        // 10 pt in `tertiaryLabelColor` was a path nobody could read — which
        // for the one line that tells you where every setting on this page
        // actually lives is the wrong end of the trade. The type is now the
        // small system size and the colour follows Increase Contrast.
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = L10n.text("settings.footer.tooltip")
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setAccessibilityLabel(L10n.text("settings.footer.pathLabel"))

        // "Reveal" named the AppKit call, not the outcome; the button says
        // what it does and to what.
        let reveal = NSButton(title: L10n.text("settings.footer.reveal"), target: self, action: #selector(revealConfigFile))
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
            let themeRow = row(L10n.text("settings.label.theme"), themePopUp)
            self.themeRow = themeRow
            rows = [
                themeRow,
                row(L10n.text("settings.label.lightOrDark"), appearancePopUp),
                // The font row states a fact and offers no control, which
                // read as a broken picker. The explanation is the fix: it
                // says why there is nothing to click, and where the one
                // remaining lever is.
                row(
                    L10n.text("settings.label.font"), fontFamilyLabel,
                    help: L10n.text("settings.help.font")),
                row(L10n.text("settings.label.size"), makeFontSizeRow()),
            ]
        case .terminal:
            rows = [
                row(
                    L10n.text("settings.label.scrollback"), scrollbackField,
                    help: L10n.text("settings.help.scrollback")),
                row(L10n.text("settings.label.bell"), bellPopUp),
                row(L10n.text("settings.label.copyOnSelect"), copyOnSelectSwitch),
                row(L10n.text("settings.label.openLinksWith"), linkActivationPopUp),
                row(
                    L10n.text("settings.label.allowClipboardCopy"), clipboardWriteSwitch,
                    help: L10n.text("settings.help.allowClipboardCopy")),
            ]
        case .general:
            rows = [
                row(
                    L10n.text("settings.label.newWindow"), makeWindowSizeRow(),
                    help: L10n.text("settings.help.newWindow")),
                row(L10n.text("settings.label.restoreWindows"), restoreWindowsSwitch),
                row(
                    L10n.text("settings.label.confirmClose"), confirmCloseSwitch,
                    help: L10n.text("settings.help.confirmClose")),
                row(
                    L10n.text("settings.label.notifyOnLongTasks"), notifySwitch,
                    help: L10n.text("settings.help.notifyOnLongTasks")),
                permissionRow(),
                makeThresholdFormRow(),
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
        // Each row spans the stack, so widening the window widens the value
        // column instead of leaving a strip of empty page on the right.
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - Rows

    private func row(
        _ title: String, _ control: NSView, help: String? = nil, indented: Bool = false
    ) -> NSView {
        row(label(title), control, help: help, indented: indented)
    }

    /// One form row: a right-aligned label, the control in the shared value
    /// column, and an optional line of grey explanation under it.
    private func row(
        _ title: NSTextField, _ control: NSView, help: String? = nil, indented: Bool = false
    ) -> NSView {
        title.alignment = .right
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        // The label-control relationship, which is what makes VoiceOver read
        // "Scrollback, text field, 10000" instead of "text field, 10000" and
        // then a stray "Scrollback" somewhere else in the pane. A separate
        // `NSTextField` next to a control is only a label to a person looking
        // at it; the two have to be told about each other.
        title.setAccessibilityRole(.staticText)
        title.cell?.setAccessibilityServesAsTitleForUIElements([control])
        control.setAccessibilityTitleUIElement(title)
        // Belt and braces: a control whose title element is not honoured (a
        // composite row's stack view, say) still has a name of its own rather
        // than being announced as an unnamed control.
        if control.accessibilityLabel() == nil {
            control.setAccessibilityLabel(title.stringValue)
        }
        if let help { control.setAccessibilityHelp(help) }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        // A dependent row is indented under the setting it belongs to, so
        // "Longer than 10 seconds" reads as part of the notification switch
        // above it rather than as a fourth independent setting.
        let indent = indented ? Self.dependentIndent : 0
        var constraints: [NSLayoutConstraint] = [
            container.widthAnchor.constraint(
                greaterThanOrEqualToConstant:
                    labelColumnWidth + Self.columnGap + Self.valueColumnWidth),

            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            title.widthAnchor.constraint(equalToConstant: labelColumnWidth - indent),
            // Against the control's centre — the only alignment that reads
            // right across a pop-up, a switch and a text field at once.
            title.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            title.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),

            control.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: labelColumnWidth + Self.columnGap),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
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
                // At least the value column, and the rest of the row when the
                // window is wider than its minimum — a wrapping explanation
                // is the first thing that should get the extra space.
                note.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: Self.valueColumnWidth),
                note.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                note.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
            helpNotes.append(note)
        } else {
            constraints.append(control.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        }

        // A pop-up sizes itself to its longest item, which puts every pop-up
        // on the page at a different width; a text field has no intrinsic
        // width worth having. Both are pinned to the value column instead.
        if control is NSPopUpButton {
            constraints += [
                control.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: Self.valueColumnWidth),
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ]
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

    /// The notification threshold, indented under the switch it depends on
    /// and held so `populate` can disable the whole row rather than just the
    /// field — an editable-looking row under an off switch is what made
    /// "Longer than" read as a setting of its own.
    /// The permission notice, in the value column under the switch. Its own
    /// row rather than the switch's `help:` line, because it appears and
    /// disappears with a system setting while the help text is constant.
    private func permissionRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        notificationPermissionNotice.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notificationPermissionNotice)
        NSLayoutConstraint.activate([
            notificationPermissionNotice.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: labelColumnWidth + Self.columnGap),
            notificationPermissionNotice.trailingAnchor.constraint(
                equalTo: container.trailingAnchor),
            notificationPermissionNotice.topAnchor.constraint(equalTo: container.topAnchor),
            notificationPermissionNotice.bottomAnchor.constraint(
                equalTo: container.bottomAnchor),
        ])
        notificationPermissionRow = container
        return container
    }

    private func makeThresholdFormRow() -> NSView {
        let created = row(thresholdLabel, makeThresholdRow(), indented: true)
        thresholdRow = created
        return created
    }

    private func makeThresholdRow() -> NSView {
        thresholdField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let suffix = NSTextField(labelWithString: L10n.text("settings.label.seconds"))
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
            let title = appearance == .auto ? L10n.text("settings.appearance.followSystem") : L10n.text("settings.appearance.\(appearance.rawValue)")
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
        fontFamilyLabel.toolTip = L10n.text("settings.font.tooltip")

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

        linkActivationPopUp.addItem(withTitle: L10n.text("settings.linkActivation.commandClick"))
        linkActivationPopUp.addItem(withTitle: L10n.text("settings.linkActivation.click"))
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
            ? L10n.text("settings.font.systemMonospaced") : configuration.fontFamily
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
        // The whole row, not only the field: the "seconds" suffix and the
        // row's own accessibility state have to say "off" too, or a screen
        // reader reports an editable setting that changes nothing.
        thresholdRow?.subviews.forEach { subview in
            if let field = subview as? NSTextField, field !== thresholdLabel {
                field.textColor =
                    configuration.notifyOnLongTask ? .labelColor : .disabledControlTextColor
            }
            (subview as? NSStackView)?.views.forEach { view in
                (view as? NSTextField)?.textColor =
                    configuration.notifyOnLongTask ? .labelColor : .disabledControlTextColor
            }
        }
        pathLabel.stringValue = ConfigurationStore.fileURL.path
        applyNotificationPermission()
        applySystemAccessibilityPreferences()
    }

    /// The notice under the notification switch: shown only when the setting
    /// is on *and* the system has been told not to deliver — the one
    /// combination in which the switch's position is not the truth.
    @objc private func applyNotificationPermission() {
        let isOn = ConfigurationStore.shared.configuration.notifyOnLongTask
        let denied = TaskNotifier.permission == .denied
        let show = isOn && denied
        notificationPermissionNotice.show(
            show ? .failed(L10n.text("settings.status.notificationsDenied")) : .none,
            retry: show ? { TaskNotifier.openSystemNotificationSettings() } : nil,
            actionTitle: show ? L10n.text("settings.status.openSystemSettings") : nil)
        if let notificationPermissionRow, notificationPermissionRow.isHidden == show {
            notificationPermissionRow.isHidden = !show
            if currentTab == .general { resizeToFitPane(animated: false) }
        }
    }

    /// Colours that have to follow Increase Contrast. Applied on every
    /// populate and whenever the system preference changes, so a switch
    /// flipped while this window is open is picked up without a relaunch.
    @objc private func applySystemAccessibilityPreferences() {
        pathLabel.textColor = SystemAccessibility.tertiaryLabelColor
        for note in helpNotes { note.textColor = SystemAccessibility.secondaryLabelColor }
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
        // Collected rather than applied silently. A field clamped from 200 to
        // 64 used to simply show 64 on the next populate, which looks exactly
        // like the app ignoring what was typed; the page now says which value
        // was adjusted and to what.
        var clamps: [String] = []
        func clamp<T: Comparable & CustomStringConvertible>(
            _ value: T, _ low: T, _ high: T, label: String
        ) -> T {
            let result = min(high, max(low, value))
            if result != value {
                clamps.append(
                    L10n.format(
                        "settings.status.clamped", label, Self.plain(low), Self.plain(high),
                        Self.plain(result)))
            }
            return result
        }
        let saved = ConfigurationStore.shared.update { configuration in
            if themeIndex < listedThemes.count {
                configuration.theme = listedThemes[themeIndex].name
            }
            configuration.appearance = Configuration.Appearance.allCases[appearanceIndex]
            if let size = Double(fontSizeField.stringValue) {
                configuration.fontSize = clamp(
                    size, 8, 64, label: L10n.text("settings.label.size"))
            }
            if let lines = Int(scrollbackField.stringValue) {
                configuration.scrollbackLines = clamp(
                    lines, 0, 1_000_000, label: L10n.text("settings.label.scrollback"))
            }
            if let columns = Int(columnsField.stringValue) {
                configuration.columns = clamp(
                    columns, 20, 500, label: L10n.text("settings.label.columns"))
            }
            if let rows = Int(rowsField.stringValue) {
                configuration.rows = clamp(
                    rows, 5, 300, label: L10n.text("settings.label.rows"))
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
                configuration.notificationThreshold = clamp(
                    seconds, 1, 86_400, label: L10n.text("settings.label.longerThan"))
            }
        }
        // A clamped or rejected value has to appear in the field, or the
        // page shows something the file does not say.
        populate()
        if !saved {
            showWriteFailure()
        } else if let first = clamps.first {
            statusView.show(.adjusted(first))
        } else {
            statusView.show(.saved)
        }
    }

    /// A bound as a person would write it. The fields hold whole numbers, but
    /// the font size and the notification threshold are `Double` — so the
    /// unformatted description said "Size must be between 8.0 and 64.0",
    /// which reads as a precision the setting does not have.
    private static func plain(_ value: CustomStringConvertible) -> String {
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// The write failed — a read-only home directory, a full disk, a
    /// `~/.config/corta` someone has made a symlink to nowhere. The page has
    /// already rolled the value back (`ConfigurationStore.update`), so the
    /// controls show what the file still says; this is what tells the user why
    /// their change did not take, and offers the one action that can help.
    private func showWriteFailure() {
        let reason =
            (ConfigurationStore.shared.lastWriteError?.localizedDescription)
            ?? L10n.text("settings.status.writeFailedUnknown")
        statusView.show(
            .failed(L10n.format("settings.status.writeFailed", reason)),
            retry: { [weak self] in self?.retryWrite() })
    }

    private func retryWrite() {
        if ConfigurationStore.shared.write() {
            statusView.show(.saved)
        } else {
            showWriteFailure()
        }
    }

    /// The store's write status changed from somewhere other than this page —
    /// an external edit that could not be re-serialised, or a retry that
    /// succeeded. Reflect it rather than leaving a stale failure on screen.
    @objc private func configurationWriteStatusChanged() {
        if ConfigurationStore.shared.lastWriteError != nil {
            showWriteFailure()
        } else {
            statusView.show(.none)
        }
    }

    /// Writes first and only reveals what it managed to write. Revealing a
    /// path whose write just failed points Finder at a file that does not say
    /// what the page says — or at no file at all on a first launch.
    @objc private func revealConfigFile() {
        guard ConfigurationStore.shared.write() else {
            showWriteFailure()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.fileURL])
    }
}
