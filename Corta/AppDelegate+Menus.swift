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

/// The menu bar, built here in full: no nib, so no template item to prune
/// or re-title. Items for a `TerminalCommand` take its title and action;
/// every key equivalent a command has comes from `Keybindings`, applied
/// after the menu exists and on every config change. The rest — AppKit's
/// own items (Hide, Quit, Minimize, …) — keep the standard shortcuts set
/// here. Items dispatch through the responder chain unless they name a
/// target.
extension AppDelegate {
    /// The submenus `menuNeedsUpdate` acts on, told apart by identity rather
    /// than by a localized title. Weak: the menu bar owns them.
    fileprivate static weak var editMenu: NSMenu?
    fileprivate static weak var themeMenu: NSMenu?

    func installMenus() {
        let mainMenu = NSMenu(title: "Main Menu")
        let services = NSMenu(title: L10n.text("menu.services"))
        let window = makeWindowMenu()
        let help = makeHelpMenu()
        for menu in [
            makeAppMenu(services: services), makeFileMenu(), makeShellMenu(), makeEditMenu(),
            makeViewMenu(), window, help,
        ] {
            mainMenu.addSubmenu(menu)
        }
        NSApp.mainMenu = mainMenu
        // AppKit fills these: the Services list, the window list and tab
        // items, and the Help search field.
        NSApp.servicesMenu = services
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        // Also here, not only in `menuNeedsUpdate`: a test host reading
        // `NSApp.mainMenu` never opens the menu.
        if let edit = AppDelegate.editMenu { pruneInjectedEditItems(edit) }
        applyKeybindings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyKeybindings), name: ConfigurationStore.didChange,
            object: nil)
    }

    private func makeAppMenu(services: NSMenu) -> NSMenu {
        let menu = NSMenu(title: L10n.text("menu.corta"))
        menu.addItem(withTitle: L10n.text("menu.aboutCorta"), action: #selector(showAboutWindow(_:)), target: self)
        // "Check for Updates…" directly under About, where Sparkle apps put it.
        if UpdateController.isAvailable {
            let update = menu.addItem(
                withTitle: L10n.text("menu.checkForUpdates"),
                action: #selector(UpdateController.checkForUpdates(_:)), target: UpdateController.shared)
            update.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        menu.addItem(item(for: .settings))
        menu.addItem(.separator())
        menu.addSubmenu(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.hideCorta"), action: #selector(NSApplication.hide(_:)), key: "h")
        menu.addItem(
            withTitle: L10n.text("menu.hideOthers"),
            action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        menu.addItem(withTitle: L10n.text("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.quitCorta"), action: #selector(NSApplication.terminate(_:)), key: "q")
        return menu
    }

    /// Export Text… sits here; the palette groups it with Edit by what it
    /// does.
    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("menu.file"))
        menu.addItem(item(for: .newWindow))
        menu.addItem(item(for: .newTab))
        menu.addItem(.separator())
        menu.addItem(item(for: .close))
        menu.addItem(.separator())
        menu.addItem(item(for: .exportText))
        menu.addItem(.separator())
        for command in [TerminalCommand.previousTab, .nextTab, .renameTab] {
            menu.addItem(item(for: command))
        }
        return menu
    }

    /// Keep frequent actions direct; related tools remain one submenu away.
    private func makeShellMenu() -> NSMenu {
        let shell = NSMenu(title: L10n.text("menu.shell"))
        installPresetMenu(in: shell)
        for command in [TerminalCommand.splitRight, .splitDown, .reopenClosedPane] {
            shell.addItem(item(for: command))
        }
        shell.addItem(.separator())
        func group(_ key: String, _ commands: [TerminalCommand]) {
            let submenu = NSMenu(title: L10n.text(key))
            for command in commands { submenu.addItem(item(for: command)) }
            shell.addSubmenu(submenu)
        }
        group("menu.focus", [.focusLeft, .focusRight, .focusUp, .focusDown])
        group("menu.commandsAndOutput", [
            .previousCommand, .nextCommand, .previousFailedCommand, .nextFailedCommand,
            .copyLastCommandOutput, .snapshotRunningCommandOutput, .exportCommandOutput,
            .openFileReferenceInCommand, .searchCommandHistory,
        ])
        group("menu.workingDirectory", [
            .revealWorkingDirectory, .copyWorkingDirectoryPath,
            .changeDirectoryToParent, .changeDirectoryToProjectRoot,
            .openParentDirectoryInNewPane, .openProjectRootInNewPane, .browseRemoteFiles,
        ])
        group("menu.paneLayout", [
            .zoomPane, .growPaneHorizontally, .shrinkPaneHorizontally,
            .growPaneVertically, .shrinkPaneVertically, .equalizePanes,
        ])
        shell.addItem(.separator())
        shell.addItem(item(for: .clearScreen))
        group("menu.terminalState", [.clearHistory, .resetTerminal, .reconnectRemote])
        shell.addItem(.separator())
        shell.addItem(item(for: .secureKeyboardEntry))
        return shell
    }

    /// Only what a terminal can honour. The child owns every byte on screen,
    /// so the text-system groups (Spelling, Substitutions, Transformations,
    /// Speech), Paste and Match Style and Find and Replace are not offered;
    /// the Find items are the four `PaneSearch.performFindPanelAction`
    /// handles (tags 1, 2, 3, 7).
    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("menu.edit"))
        menu.addItem(withTitle: L10n.text("menu.undo"), action: Selector(("undo:")), key: "z")
        menu.addItem(withTitle: L10n.text("menu.redo"), action: Selector(("redo:")), key: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.cut"), action: #selector(NSText.cut(_:)), key: "x")
        menu.addItem(item(for: .copy))
        menu.addItem(item(for: .paste))
        menu.addItem(withTitle: L10n.text("menu.delete"), action: #selector(NSText.delete(_:)))
        menu.addItem(item(for: .selectAll))
        menu.addItem(.separator())
        let find = NSMenu(title: L10n.text("menu.find"))
        find.addItem(item(for: .find))
        for (key, tag, keyEquivalent) in [
            ("menu.findNext", 2, "g"), ("menu.findPrevious", 3, "G"), ("menu.useSelectionForFind", 7, "e"),
        ] {
            let item = find.addItem(
                withTitle: L10n.text(key), action: #selector(PaneSearch.performFindPanelAction(_:)),
                key: keyEquivalent)
            item.tag = tag
        }
        menu.addSubmenu(find)
        // AppKit injects AutoFill, Dictation and Emoji & Symbols later, and
        // again; see `menuNeedsUpdate`.
        menu.delegate = self
        AppDelegate.editMenu = menu
        return menu
    }

    /// Theme, appearance, scrolling and the palette. Theme and appearance
    /// share one submenu — they are one daily choice — and a separate
    /// Settings menu would duplicate the app menu's ⌘,.
    private func makeViewMenu() -> NSMenu {
        let view = NSMenu(title: L10n.text("menu.view"))
        for command in [TerminalCommand.increaseFontSize, .decreaseFontSize, .resetFontSize] {
            view.addItem(item(for: command))
        }
        view.addItem(
            withTitle: L10n.text("menu.enterFullScreen"), action: #selector(NSWindow.toggleFullScreen(_:)),
            key: "f", modifiers: [.command, .control])
        view.addItem(.separator())
        for command in [
            TerminalCommand.scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
        ] {
            view.addItem(item(for: command))
        }
        view.addItem(.separator())
        view.addItem(item(for: .commandPalette))
        // No key equivalent: the system-wide hotkey is `quick-terminal-key`,
        // held by `GlobalHotKey`.
        view.addItem(item(for: .quickTerminal))
        view.addItem(.separator())

        view.addSubmenu(makeThemeMenu())
        view.addItem(withTitle: L10n.text("theme.editor") + "…", action: #selector(showThemeEditor(_:)), target: self)
        view.addItem(withTitle: L10n.text("status.details") + "…", action: #selector(showHostDetails(_:)), target: self)
        return view
    }

    /// `NSApp.windowsMenu`: AppKit appends the window list and the tab items.
    private func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("menu.window"))
        menu.addItem(withTitle: L10n.text("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        menu.addItem(withTitle: L10n.text("menu.zoom"), action: #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }

    /// "Corta Help" (⌘?) opens the documentation — Corta ships no help book;
    /// Keyboard Shortcuts (⌘/, as elsewhere) opens `ShortcutsWindowController`.
    private func makeHelpMenu() -> NSMenu {
        let help = NSMenu(title: L10n.text("menu.help"))
        help.addItem(withTitle: L10n.text("menu.cortaHelp"), action: #selector(showHelpDocumentation(_:)), key: "?", target: self)
        help.addItem(.separator())
        help.addItem(withTitle: L10n.text("shortcuts.title"), action: #selector(showShortcutsWindow(_:)), key: "/", target: self)
        #if DEBUG
        help.addItem(withTitle: L10n.text("ui.demo.title"), action: #selector(showSFTPDevelopmentPreview(_:)), target: self)
        #endif
        return help
    }

    /// "Corta Help" (⌘?) opens the README, which links on to `docs/`.
    @objc func showHelpDocumentation(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    static let helpURL = URL(string: "https://github.com/noah-qin/Corta#readme")!

    @objc func showShortcutsWindow(_ sender: Any?) {
        ShortcutsWindowController.shared.show(sender)
    }

    @objc func showAboutWindow(_ sender: Any?) {
        AboutWindowController.shared.show(sender)
    }

    /// Drops AutoFill and Start Dictation as the Edit menu opens; AppKit
    /// re-injects them, and both need a Cocoa text object Corta lacks. Emoji &
    /// Symbols stays: `TerminalView`'s `NSTextInputClient` takes its input.
    func pruneInjectedEditItems(_ menu: NSMenu) {
        let injected: Set<Selector> = [
            Selector(("_autoFillMenu:")),
            Selector(("startDictation:")),
        ]
        for item in menu.items.reversed() {
            let matchesAction = item.action.map(injected.contains) ?? false
            let matchesAutoFill = item.submenu != nil && item.title == "AutoFill"
            guard matchesAction || matchesAutoFill else { continue }
            menu.removeItem(item)
        }
        deduplicateInjectedItems(menu)
        tidySeparators(in: menu)
    }

    /// Removes same-title, same-keystroke duplicates, keeping the first. A CI
    /// runner with no interactive session got two Emoji & Symbols items
    /// (`MenuShortcutTests.noKeystrokeIsClaimedByTwoMenuItems`); AppKit's
    /// injection isn't ours to key off.
    private func deduplicateInjectedItems(_ menu: NSMenu) {
        var seen: Set<String> = []
        for item in menu.items.reversed() {
            guard !item.title.isEmpty else { continue }
            let identity = "\(item.title)\u{0}\(item.keyEquivalent)\u{0}\(item.keyEquivalentModifierMask.rawValue)"
            if seen.contains(identity) {
                menu.removeItem(item)
            } else {
                seen.insert(identity)
            }
        }
    }

    /// Drops leading, trailing and doubled separators.
    private func tidySeparators(in menu: NSMenu) {
        var index = menu.items.count - 1
        while index >= 0 {
            let item = menu.items[index]
            if item.isSeparatorItem {
                let isLast = index == menu.items.count - 1
                let isFirst = index == 0
                let followsSeparator = index > 0 && menu.items[index - 1].isSeparatorItem
                if isLast || isFirst || followsSeparator { menu.removeItem(at: index) }
            }
            index -= 1
        }
    }

    /// Rebuilt from the configuration as the menu opens, so a theme defined
    /// at runtime appears.
    private func makeThemeMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("settings.label.theme"))
        menu.delegate = self
        rebuildThemeMenu(menu)
        AppDelegate.themeMenu = menu
        return menu
    }

    func rebuildThemeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, appearance) in Configuration.Appearance.allCases.enumerated() {
            let title = appearance == .auto ? L10n.text("settings.appearance.followSystem") : L10n.text("settings.appearance.\(appearance.rawValue)")
            let item = NSMenuItem(
                title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, theme) in Theme.all(in: ConfigurationStore.shared.configuration).enumerated() {
            let item = NSMenuItem(
                title: theme.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
    }

    private func item(for command: TerminalCommand) -> NSMenuItem {
        // No target: the responder chain picks the focused window and pane.
        let item = NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
        if let tag = command.menuTag { item.tag = tag }
        return item
    }

    /// Applies every command's shortcut to its menu items, at launch and on
    /// each config change, so an unbind clears the menu too.
    @objc func applyKeybindings() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let bindings = ConfigurationStore.shared.configuration.keybindings
        for command in TerminalCommand.allCases {
            let shortcut = bindings[command]
            apply(shortcut, to: command, in: mainMenu)
        }
    }

    private func apply(_ shortcut: Shortcut?, to command: TerminalCommand, in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { apply(shortcut, to: command, in: submenu) }
            guard item.action == command.action else { continue }
            // Four Find items share `performFindPanelAction:`; match the tag.
            if let tag = command.menuTag, item.tag != tag { continue }
            item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
            item.keyEquivalentModifierMask = shortcut?.menuModifierMask ?? []
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === AppDelegate.editMenu {
            pruneInjectedEditItems(menu)
            return
        }
        if menu === AppDelegate.presetMenu {
            rebuildPresetMenu(menu)
            return
        }
        guard menu === AppDelegate.themeMenu else { return }
        rebuildThemeMenu(menu)
    }
}

extension NSMenu {
    /// A parent item for `submenu`, titled as it is.
    @discardableResult
    func addSubmenu(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }

    /// An item with a key equivalent, ⌘ unless `modifiers` says otherwise.
    @discardableResult
    fileprivate func addItem(
        withTitle title: String, action: Selector, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        addItem(item)
        return item
    }
}

#if DEBUG
extension AppDelegate {
    @objc func showSFTPDevelopmentPreview(_ sender: Any?) { SFTPBrowserController.showDevelopmentPreview() }
}
#endif
