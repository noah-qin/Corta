import AppKit

/// M6.1 — the settings page.
///
/// One page, built in code rather than a nib: the whole content is a
/// two-column grid of labels and controls, which `NSGridView` lays out in a
/// dozen lines and a nib would spread across a separate file with no gain.
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
    private let notifySwitch = NSSwitch()
    private let thresholdField = NSTextField()
    private let pathLabel = NSTextField(labelWithString: "")
    /// Suppresses the write-back while the page is being populated from the
    /// store — otherwise setting a control's value looks like a user edit
    /// and writes the file back at itself.
    private var isPopulating = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Corta Settings"
        window.isReleasedWhenClosed = false
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
        for theme in Theme.builtIn { themePopUp.addItem(withTitle: theme.displayName) }
        themePopUp.target = self
        themePopUp.action = #selector(commit)

        for appearance in Configuration.Appearance.allCases {
            appearancePopUp.addItem(withTitle: appearance.rawValue.capitalized)
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(commit)

        fontFamilyPopUp.addItem(withTitle: "System Monospaced")
        // Only the monospaced faces: a proportional font in a grid terminal
        // is not a preference, it is a defect.
        for family in Self.monospacedFamilies { fontFamilyPopUp.addItem(withTitle: family) }
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
            bellPopUp.addItem(withTitle: mode.rawValue.capitalized)
        }
        bellPopUp.target = self
        bellPopUp.action = #selector(commit)

        notifySwitch.target = self
        notifySwitch.action = #selector(commit)
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

        let grid = NSGridView(views: [
            [label("Theme"), themePopUp],
            [label("Appearance"), appearancePopUp],
            [label("Font"), fontFamilyPopUp],
            [label("Size"), fontSizeRow],
            [label("Scrollback"), scrollbackField],
            [label("Bell"), bellPopUp],
            [label("Notify on long tasks"), notifySwitch],
            [label("Longer than"), thresholdRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 12

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let reveal = NSButton(
            title: "Reveal Config File", target: self, action: #selector(revealConfigFile))
        reveal.bezelStyle = .rounded

        let footer = NSStackView(views: [pathLabel, reveal])
        footer.orientation = .horizontal
        footer.spacing = 12

        let stack = NSStackView(views: [grid, NSBox.horizontalSeparator(), footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        return content
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// Every installed family whose faces are fixed-pitch, sorted. Asked of
    /// AppKit rather than hardcoded so a font the user installs shows up.
    private static var monospacedFamilies: [String] {
        let manager = NSFontManager.shared
        return (manager.availableFontFamilies).filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family),
                let first = members.first, first.count > 0,
                let name = first[0] as? String, let font = NSFont(name: name, size: 12)
            else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    // MARK: - Store <-> controls

    @objc private func populate() {
        isPopulating = true
        defer { isPopulating = false }
        let configuration = ConfigurationStore.shared.configuration

        if let index = Theme.builtIn.firstIndex(where: { $0.name == configuration.theme }) {
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
        bellPopUp.selectItem(withTitle: configuration.bell.rawValue.capitalized)
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
            configuration.theme = Theme.builtIn[themeIndex].name
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
