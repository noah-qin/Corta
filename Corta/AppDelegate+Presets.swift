// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Cocoa

/// The Shell menu's list of presets, rebuilt from the config file each
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
    /// The submenu itself, for `menuNeedsUpdate` to recognise by identity.
    static weak var presetMenu: NSMenu?

    fileprivate var presetMenuItem: NSMenuItem? {
        get { AppDelegate.presetItem }
        set { AppDelegate.presetItem = newValue }
    }

    fileprivate var presetMenuSeparator: NSMenuItem? {
        get { AppDelegate.presetSeparator }
        set { AppDelegate.presetSeparator = newValue }
    }

    /// The submenu's title.
    static var presetMenuTitle: String { L10n.text("menu.presets") }

    /// Appends the preset row and its separator to `shell`.
    func installPresetMenu(in shell: NSMenu) {
        let submenu = NSMenu(title: Self.presetMenuTitle)
        submenu.delegate = self
        rebuildPresetMenu(submenu)
        Self.presetMenu = submenu
        let item = shell.addSubmenu(submenu)
        let separator = NSMenuItem.separator()
        shell.addItem(separator)
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
            // Holding ⌥ opens the preset in a window of its own. An
            // alternate item is the Mac idiom for "the same command, one
            // level bigger", and it costs no extra row until ⌥ is down.
            let inWindow = NSMenuItem(
                title: L10n.format("menu.presetInWindow", preset.name),
                action: #selector(openPresetInWindow(_:)), keyEquivalent: "")
            inWindow.tag = index
            inWindow.target = self
            inWindow.isAlternate = true
            inWindow.keyEquivalentModifierMask = [.option]
            inWindow.toolTip = Self.summary(of: preset)
            menu.addItem(inWindow)
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
        open(sender, inNewWindow: false)
    }

    /// ⌥-choosing a preset: a window of its own rather than a split.
    @objc func openPresetInWindow(_ sender: Any?) {
        open(sender, inNewWindow: true)
    }

    private func open(_ sender: Any?, inNewWindow: Bool) {
        guard let item = sender as? NSMenuItem else { return }
        let presets = ConfigurationStore.shared.configuration.presets
        guard item.tag >= 0, item.tag < presets.count else { return }
        launchPreset(presets[item.tag], inNewWindow: inNewWindow)
    }

    func launchPreset(_ preset: Preset, inNewWindow: Bool) {
        if !inNewWindow,
            let split = NSApp.keyWindow?.contentViewController as? SplitViewController
        {
            split.splitFocusedPane(orientation: .columns, preset: preset)
            return
        }
        // A new window's own first pane is created as its view loads, so the
        // preset is staged before that happens rather than opening a second
        // pane and closing the first — which is what an extra split would be.
        guard
            let controller = instantiateWindowController(
                setup: SplitViewController.Setup(preset: preset))
        else { return }
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }
}
