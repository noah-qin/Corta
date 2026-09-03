import AppKit

/// M6.1 — the settings page.
///
/// One page, built in code rather than a nib: the whole content is a stack of
/// labelled sections, which AppKit lays out in a screenful of code and a nib
/// would spread across a separate file with no gain.
///
/// **Grouping is not decoration.** The page grew to a dozen controls in one
/// flat grid, where "Bell" sat between "Scrollback" and a notification switch
/// and nothing said which of them affected the terminal surface, which
/// affected the window, and which talked to Notification Center. The controls
/// are the same; they are now in named sections, several carry a line of
/// explanation, and the window resizes and scrolls so a long font-family name
/// is not truncated at a fixed 460 points.
///
/// Every control writes through `ConfigurationStore.update`, which writes
/// the file and re-reads it. Nothing here holds state of its own — the page
/// re-populates from the store on `ConfigurationStore.didChange`, so an edit
/// made in `$EDITOR` while this window is open moves the controls, and the
/// two directions cannot disagree.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let themePopUp = NSPopUpButton()
    private let appearancePopUp = NSPopUpButton()
    private let fontFamilyPopUp = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let scrollbackField = NSTextField()
    private let bellPopUp = NSPopUpButton()
    private let copyOnSelectSwitch = NSSwitch()
    private let linkActivationPopUp = NSPopUpButton()
    private let clipboardWriteSwitch = NSSwitch()
    private let restoreWindowsSwitch = NSSwitch()
    private let confirmCloseSwitch = NSSwitch()
    private let notifySwitch = NSSwitch()
    private let thresholdField = NSTextField()
    private let pathLabel = NSTextField(labelWithString: "")
    /// The themes the popup currently lists, in its own order — the built-ins
    /// plus whatever the config file defines, so a custom theme can be picked
    /// from the page and not only by hand-editing the file.
    private var listedThemes: [Theme] = []
    /// Suppresses the write-back while the page is being populated from the
    /// store — otherwise setting a control's value looks like a user edit
    /// and writes the file back at itself.
    private var isPopulating = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            // Resizable: the font list carries family names as long as
            // "Source Code Pro Semibold", and a fixed 460pt window truncated
            // them with no way to widen it.
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Corta Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 400)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContentView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(populate), name: ConfigurationStore.didChange, object: nil)
        populate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        // The file may not exist until something writes it; writing on first
        // open is what makes the format discoverable and gives "Reveal in
        // Finder" something to reveal.
        ConfigurationStore.shared.write()
        populate()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        themePopUp.target = self
        themePopUp.action = #selector(commit)

        for appearance in Configuration.Appearance.allCases {
            let title = appearance == .auto ? "Follow System" : appearance.rawValue.capitalized
            appearancePopUp.addItem(withTitle: title)
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(commit)

        fontFamilyPopUp.addItem(withTitle: "System Monospaced")
        // Only families that actually render on a grid — uniform ASCII
        // advances across the regular, bold, italic and bold-italic faces,
        // and real outlines. `isFixedPitch` on one face is not that test;
        // `MonospacedFontCatalog` explains what each check buys.
        for family in MonospacedFontCatalog.families() { fontFamilyPopUp.addItem(withTitle: family) }
        fontFamilyPopUp.target = self
        fontFamilyPopUp.action = #selector(commit)

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

        for mode in [BellMode.visual, .audible, .muted] {
            bellPopUp.addItem(withTitle: mode.displayName)
        }
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

        let fontSizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        fontSizeRow.spacing = 4
        fontSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        scrollbackField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        thresholdField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let thresholdRow = NSStackView(views: [
            thresholdField, NSTextField(labelWithString: "seconds"),
        ])
        thresholdRow.spacing = 6

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(
            title: "Reveal Config File", target: self, action: #selector(revealConfigFile))
        reveal.bezelStyle = .rounded
        reveal.setContentHuggingPriority(.required, for: .horizontal)

        let footer = NSStackView(views: [pathLabel, reveal])
        footer.orientation = .horizontal
        footer.spacing = 12

        let stack = NSStackView(views: [
            section(
                "Appearance",
                rows: [
                    (
                        "Theme", themePopUp,
                        "Built-in themes, plus any the config file defines."
                    ),
                    ("Light or dark", appearancePopUp, nil),
                ]),
            section(
                "Font",
                rows: [
                    (
                        "Family", fontFamilyPopUp,
                        "Only families whose glyphs all advance by one cell are listed."
                    ),
                    ("Size", fontSizeRow, nil),
                ]),
            section(
                "Terminal",
                rows: [
                    ("Scrollback", scrollbackField, "Lines of history kept per session."),
                    ("Bell", bellPopUp, nil),
                    ("Copy on select", copyOnSelectSwitch, nil),
                    ("Open links with", linkActivationPopUp, nil),
                    (
                        "Allow OSC 52 copy", clipboardWriteSwitch,
                        "Off by default: any output could place text on the clipboard. Reading it is never allowed."
                    ),
                ]),
            section(
                "Windows",
                rows: [
                    (
                        "Restore on launch", restoreWindowsSwitch,
                        "Reopen the last run's windows, splits and working directories."
                    ),
                    (
                        "Confirm close", confirmCloseSwitch,
                        "Ask before closing a pane that still has something running."
                    ),
                ]),
            section(
                "Notifications",
                rows: [
                    ("Notify on long tasks", notifySwitch, nil),
                    ("Longer than", thresholdRow, nil),
                ]),
            NSBox.horizontalSeparator(),
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrolled, because a settings page that grows a section must not
        // become a window that cannot show its last row on a small display.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scrollView.documentView = documentView
        // The width tracks the clip view so rows widen with the window; the
        // height is the content's own, which is what makes it scroll.
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        return scrollView
    }

    /// One named group of rows: a bold header, then a two-column grid of
    /// labels and controls, with an optional line of grey explanation under
    /// any row that needs one.
    private func section(_ title: String, rows: [(String, NSView, String?)]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        var gridRows: [[NSView]] = []
        for (label, control, help) in rows {
            gridRows.append([self.label(label), control])
            if let help {
                let note = NSTextField(wrappingLabelWithString: help)
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                note.preferredMaxLayoutWidth = 320
                gridRows.append([NSGridCell.emptyContentView, note])
            }
        }
        let grid = NSGridView(views: gridRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

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

        if let index = Configuration.Appearance.allCases.firstIndex(of: configuration.appearance) {
            appearancePopUp.selectItem(at: index)
        }
        if configuration.fontFamily == Configuration.systemFontFamily {
            fontFamilyPopUp.selectItem(at: 0)
        } else {
            fontFamilyPopUp.selectItem(withTitle: configuration.fontFamily)
            if fontFamilyPopUp.indexOfSelectedItem < 0 { fontFamilyPopUp.selectItem(at: 0) }
        }
        fontSizeField.stringValue = String(Int(configuration.fontSize))
        fontSizeStepper.doubleValue = configuration.fontSize
        scrollbackField.stringValue = String(configuration.scrollbackLines)
        bellPopUp.selectItem(withTitle: configuration.bell.displayName)
        copyOnSelectSwitch.state = configuration.copyOnSelect ? .on : .off
        linkActivationPopUp.selectItem(at: configuration.linkActivation == .click ? 1 : 0)
        clipboardWriteSwitch.state = configuration.allowClipboardWrite ? .on : .off
        restoreWindowsSwitch.state = configuration.restoreWindows ? .on : .off
        confirmCloseSwitch.state = configuration.confirmClose ? .on : .off
        notifySwitch.state = configuration.notifyOnLongTask ? .on : .off
        thresholdField.stringValue = String(Int(configuration.notificationThreshold))
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
        ConfigurationStore.shared.update { configuration in
            if themeIndex < listedThemes.count {
                configuration.theme = listedThemes[themeIndex].name
            }
            configuration.appearance = Configuration.Appearance.allCases[appearanceIndex]
            configuration.fontFamily =
                fontFamilyPopUp.indexOfSelectedItem <= 0
                ? Configuration.systemFontFamily
                : (fontFamilyPopUp.titleOfSelectedItem ?? Configuration.systemFontFamily)
            if let size = Double(fontSizeField.stringValue) {
                configuration.fontSize = min(64, max(8, size))
            }
            if let lines = Int(scrollbackField.stringValue) {
                configuration.scrollbackLines = min(1_000_000, max(0, lines))
            }
            configuration.bell =
                BellMode(rawValue: (bellPopUp.titleOfSelectedItem ?? "visual").lowercased())
                ?? .visual
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

extension NSBox {
    fileprivate static func horizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
