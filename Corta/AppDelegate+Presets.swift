import Cocoa

/// U16 — the Shell menu's list of presets, rebuilt from the config file each
/// time the menu opens.
///
/// Rebuilt rather than built once at launch, for the same reason the theme
/// list is: the config file can gain a preset while the app is running, and a
/// menu built at launch would never show it. The list is absent entirely when
/// no preset is defined — an empty submenu called "New Pane with Preset" is a
/// promise of a feature the user has not set up, and the `CONFIGURATION.md`
/// section is where they would learn to.
extension AppDelegate {
    /// The preset row and the separator under it, so both can be hidden when
    /// the config file defines no presets. Weak: the menu bar owns them.
    fileprivate static weak var presetItem: NSMenuItem?
    fileprivate static weak var presetSeparator: NSMenuItem?

    fileprivate var presetMenuItem: NSMenuItem? {
        get { AppDelegate.presetItem }
        set { AppDelegate.presetItem = newValue }
    }

    fileprivate var presetMenuSeparator: NSMenuItem? {
        get { AppDelegate.presetSeparator }
        set { AppDelegate.presetSeparator = newValue }
    }

    /// The submenu's title, used to recognise it in `menuNeedsUpdate`
    /// without matching on a stored reference.
    static var presetMenuTitle: String { L10n.text("menu.presets") }

    func installPresetMenu(in mainMenu: NSMenu) {
        guard let shell = mainMenu.items.first(where: { $0.title == "Shell" })?.submenu
        else { return }
        let item = NSMenuItem(title: Self.presetMenuTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: Self.presetMenuTitle)
        submenu.delegate = self
        item.submenu = submenu
        rebuildPresetMenu(submenu)
        let separator = NSMenuItem.separator()
        shell.insertItem(separator, at: 0)
        shell.insertItem(item, at: 0)
        presetMenuItem = item
        presetMenuSeparator = separator
        updatePresetMenuVisibility()
        // The config file can gain or lose a preset while the app is running,
        // so the row appears and disappears with it rather than only at
        // launch — the same reason the theme list is rebuilt on open.
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePresetMenuVisibility),
            name: ConfigurationStore.didChange, object: nil)
    }

    /// Hides the row entirely when the config file defines no presets.
    ///
    /// Hidden, not disabled: a submenu's parent item carries no action, so
    /// `validateMenuItem` is never asked about it and AppKit enables it
    /// unconditionally — an always-enabled row that opens an empty menu, as a
    /// live run showed. `isHidden` is the one property automatic enabling
    /// does not override.
    @objc func updatePresetMenuVisibility() {
        let hasPresets = !ConfigurationStore.shared.configuration.presets.isEmpty
        presetMenuItem?.isHidden = !hasPresets
        presetMenuSeparator?.isHidden = !hasPresets
    }

    func rebuildPresetMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let presets = ConfigurationStore.shared.configuration.presets
        guard !presets.isEmpty else {
            // Not a disabled row saying "no presets" — a menu that explains
            // its own emptiness is still a menu the user opened for nothing.
            // The item itself is disabled by `validateMenuItem` instead.
            return
        }
        for (index, preset) in presets.enumerated() {
            let item = NSMenuItem(
                title: preset.name, action: #selector(openPreset(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.toolTip = Self.summary(of: preset)
            menu.addItem(item)
        }
    }

    /// What the preset will actually do, for the tooltip: a person choosing
    /// between three presets named after projects needs to see which shell
    /// and directory each one means.
    static func summary(of preset: Preset) -> String {
        var parts: [String] = []
        if let shell = preset.shell { parts.append(shell) }
        if let directory = preset.directory { parts.append(directory) }
        if !preset.environment.isEmpty {
            parts.append(preset.environment.keys.sorted().joined(separator: ", "))
        }
        return parts.joined(separator: " — ")
    }

    /// Opens the preset as a split of the focused pane, or as the first pane
    /// of a new window when there is no window to split.
    @objc func openPreset(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let presets = ConfigurationStore.shared.configuration.presets
        guard item.tag >= 0, item.tag < presets.count else { return }
        let preset = presets[item.tag]
        guard let split = NSApp.keyWindow?.contentViewController as? SplitViewController
        else {
            newDocument(nil)
            // The new window's own first pane is already spawning by the time
            // this returns, so the preset opens as a split inside it rather
            // than replacing it — one extra pane, and no race with a pane
            // that is mid-spawn.
            (NSApp.keyWindow?.contentViewController as? SplitViewController)?
                .splitFocusedPane(orientation: .columns, preset: preset)
            return
        }
        split.splitFocusedPane(orientation: .columns, preset: preset)
    }
}
