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

/// The menu bar: items the storyboard can't carry, and every key
/// equivalent. Shortcuts are applied from `Keybindings` after the menu
/// exists and on every config change, because a nib's key equivalent can't
/// be rebound. Menu items still dispatch through the responder chain, and
/// the menus show the shortcut that actually works.
extension AppDelegate {
    /// Lets `menuNeedsUpdate` tell Edit from the theme menu without a
    /// localized title.
    fileprivate static weak var editMenu: NSMenu?

    func installMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        installAboutItem(in: mainMenu)
        installUpdateItem(in: mainMenu)
        installFileMenuItems(in: mainMenu)
        installShellMenuItems(in: mainMenu)
        installPresetMenu(in: mainMenu)
        installViewMenuItems(in: mainMenu)
        installHelpMenuItems(in: mainMenu)
        pruneInapplicableEditItems(in: mainMenu)
        // Also here, not only in `menuNeedsUpdate`: a test host reading
        // `NSApp.mainMenu` never opens the menu.
        if let edit = AppDelegate.editMenu { pruneInjectedEditItems(edit) }
        localizeStoryboardMenuTitles(in: mainMenu)
        applyKeybindings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyKeybindings), name: ConfigurationStore.didChange,
            object: nil)
    }

    /// Storyboard items stay in the base storyboard for their responder-chain
    /// wiring; titles are localized here from the String Catalog.
    private func localizeStoryboardMenuTitles(in menu: NSMenu) {
        let titles: [String: String] = [
            "Corta": "menu.corta", "About Corta": "menu.aboutCorta", "Settings…": "command.settings",
            "Services": "menu.services", "Hide Corta": "menu.hideCorta", "Hide Others": "menu.hideOthers",
            "Show All": "menu.showAll", "Quit Corta": "menu.quitCorta", "File": "menu.file",
            // "New" says New Window, as the palette and shortcuts sheet do.
            "New": "command.newWindow", "New Tab": "command.newTab", "Close": "command.close",
            "Shell": "menu.shell", "Split Pane Right": "command.splitRight", "Split Pane Down": "command.splitDown",
            "Move Focus Left": "command.focusLeft", "Move Focus Right": "command.focusRight",
            "Move Focus Up": "command.focusUp", "Move Focus Down": "command.focusDown", "Edit": "menu.edit",
            "Undo": "menu.undo", "Redo": "menu.redo", "Cut": "menu.cut", "Copy": "common.copy",
            "Paste": "common.paste", "Paste and Match Style": "menu.pasteAndMatchStyle", "Delete": "menu.delete",
            "Select All": "common.selectAll", "Find": "menu.find", "Find…": "command.find",
            "Find Next": "menu.findNext", "Find Previous": "menu.findPrevious",
            "Use Selection for Find": "menu.useSelectionForFind", "Jump to Selection": "menu.jumpToSelection",
            "View": "menu.view", "Bigger": "command.increaseFontSize", "Smaller": "command.decreaseFontSize",
            "Actual Size": "command.resetFontSize", "Enter Full Screen": "menu.enterFullScreen", "Window": "menu.window",
            "Minimize": "menu.minimize", "Zoom": "menu.zoom", "Bring All to Front": "menu.bringAllToFront",
            "Help": "menu.help", "Corta Help": "menu.cortaHelp", "Spelling and Grammar": "menu.spellingGrammar",
            "Spelling": "menu.spelling", "Show Spelling and Grammar": "menu.showSpellingGrammar",
            "Check Document Now": "menu.checkDocument", "Check Spelling While Typing": "menu.checkSpelling",
            "Check Grammar With Spelling": "menu.checkGrammar", "Correct Spelling Automatically": "menu.correctSpelling",
            "Substitutions": "menu.substitutions", "Show Substitutions": "menu.showSubstitutions",
            "Smart Copy/Paste": "menu.smartCopyPaste", "Smart Quotes": "menu.smartQuotes",
            "Smart Dashes": "menu.smartDashes", "Smart Links": "menu.smartLinks",
            "Data Detectors": "menu.dataDetectors", "Text Replacement": "menu.textReplacement",
            "Transformations": "menu.transformations", "Make Upper Case": "menu.upperCase",
            "Make Lower Case": "menu.lowerCase", "Capitalize": "menu.capitalize", "Speech": "menu.speech",
            "Start Speaking": "menu.startSpeaking", "Stop Speaking": "menu.stopSpeaking"
        ]
        for item in menu.items {
            if let key = titles[item.title] { item.title = L10n.text(key) }
            if let submenu = item.submenu {
                // The bar shows a submenu's title, not its item's; localize both.
                if let key = titles[submenu.title] { submenu.title = L10n.text(key) }
                localizeStoryboardMenuTitles(in: submenu)
            }
        }
    }

    /// Help > Keyboard Shortcuts (⌘/, as elsewhere) opens
    /// `ShortcutsWindowController`.
    private func installHelpMenuItems(in mainMenu: NSMenu) {
        guard let help = mainMenu.items.first(where: { $0.title == "Help" })?.submenu
        else { return }
        // The template's "Corta Help" opens a help book Corta never shipped;
        // retarget it at the documentation, matched by action.
        if let cortaHelp = help.items.first(where: {
            $0.action == #selector(NSApplication.showHelp(_:))
        }) {
            cortaHelp.action = #selector(showHelpDocumentation(_:))
            cortaHelp.target = self
        }
        let item = NSMenuItem(
            title: L10n.text("shortcuts.title"), action: #selector(showShortcutsWindow(_:)),
            keyEquivalent: "/")
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        help.addItem(.separator())
        help.addItem(item)
        #if DEBUG
        let preview = NSMenuItem(title: L10n.text("ui.demo.title"), action: #selector(showSFTPDevelopmentPreview(_:)), keyEquivalent: "")
        preview.target = self
        help.addItem(preview)
        #endif
    }

    /// "Corta Help" (⌘?) opens the README, which links on to `docs/`.
    @objc func showHelpDocumentation(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    static let helpURL = URL(string: "https://github.com/noah-qin/Corta#readme")!

    @objc func showShortcutsWindow(_ sender: Any?) {
        ShortcutsWindowController.shared.show(sender)
    }

    /// Removes template Edit items only an `NSTextView` can honour: Spelling
    /// and Grammar, Substitutions, Transformations, Speech, Paste and Match
    /// Style, and Find and Replace. The child owns every byte on screen, so
    /// these were greyed out or silently did nothing
    /// (`ViewController.performFindPanelAction` handles only tags 1, 2, 3, 7).
    ///
    /// Removed by action (or, for the three template submenus, by their
    /// children's actions), so localized menus prune the same items.
    private func pruneInapplicableEditItems(in mainMenu: NSMenu) {
        guard let edit = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu
        else { return }

        // Spelling and Grammar, Substitutions, Transformations, Speech.
        let templateActions: Set<Selector> = [
            #selector(NSText.showGuessPanel(_:)),
            #selector(NSText.checkSpelling(_:)),
            #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
            #selector(NSTextView.uppercaseWord(_:)),
            #selector(NSTextView.startSpeaking(_:)),
        ]
        func isTemplateGroup(_ item: NSMenuItem) -> Bool {
            guard let submenu = item.submenu else { return false }
            return submenu.items.contains { child in
                guard let action = child.action else { return false }
                if templateActions.contains(action) { return true }
                return child.submenu?.items.contains {
                    $0.action.map(templateActions.contains) ?? false
                } ?? false
            }
        }

        // Paste and Match Style: a PTY has no style.
        let removableActions: Set<Selector> = [
            #selector(NSTextView.pasteAsPlainText(_:))
        ]
        // Find, Next, Previous, Use Selection (`performFindPanelAction`).
        let keptFindTags: Set<Int> = [1, 2, 3, 7]

        for item in edit.items.reversed() {
            if isTemplateGroup(item) {
                edit.removeItem(item)
                continue
            }
            if let action = item.action, removableActions.contains(action) {
                edit.removeItem(item)
                continue
            }
            guard let find = item.submenu,
                find.items.contains(where: {
                    $0.action == #selector(NSResponder.performTextFinderAction(_:))
                        || $0.action
                            == #selector(ViewController.performFindPanelAction(_:))
                })
            else { continue }
            for candidate in find.items.reversed()
            where candidate.action != nil && !keptFindTags.contains(candidate.tag) {
                find.removeItem(candidate)
            }
        }
        tidySeparators(in: edit)
        // AppKit injects AutoFill and Dictation later, and again; see
        // `menuNeedsUpdate`.
        edit.delegate = self
        AppDelegate.editMenu = edit
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

    /// Points "About Corta" at Corta's About window. AppKit's template
    /// attaches `orderFrontStandardAboutPanel:`; matched by that action, since
    /// the title is localized.
    private func installAboutItem(in mainMenu: NSMenu) {
        guard let appMenu = mainMenu.items.first?.submenu,
            let about = appMenu.items.first(where: {
                $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            })
        else { return }
        about.action = #selector(showAboutWindow(_:))
        about.target = self
    }

    @objc func showAboutWindow(_ sender: Any?) {
        AboutWindowController.shared.show(sender)
    }

    /// "Check for Updates…", inserted directly under About, where Sparkle apps
    /// put it.
    private func installUpdateItem(in mainMenu: NSMenu) {
        guard UpdateController.isAvailable else { return }
        guard let appMenu = mainMenu.items.first?.submenu,
            let about = appMenu.items.first(where: {
                $0.action == #selector(showAboutWindow(_:))
            }),
            let aboutIndex = appMenu.items.firstIndex(of: about)
        else { return }
        let item = NSMenuItem(
            title: L10n.text("menu.checkForUpdates"),
            action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = UpdateController.shared
        item.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        appMenu.insertItem(item, at: aboutIndex + 1)
    }

    /// Keep frequent actions direct; related tools remain one submenu away.
    private func installShellMenuItems(in mainMenu: NSMenu) {
        guard let shell = mainMenu.items.first(where: { $0.title == "Shell" })?.submenu
        else { return }
        shell.removeAllItems()
        for command in [TerminalCommand.splitRight, .splitDown, .reopenClosedPane] {
            shell.addItem(item(for: command))
        }
        shell.addItem(.separator())
        func group(_ key: String, _ commands: [TerminalCommand]) {
            let title = L10n.text(key)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for command in commands { submenu.addItem(item(for: command)) }
            parent.submenu = submenu
            shell.addItem(parent)
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
    }

    /// Export Text…, under File. (The palette groups it with Edit by what it
    /// does.)
    private func installFileMenuItems(in mainMenu: NSMenu) {
        guard let file = mainMenu.items.first(where: { $0.title == "File" })?.submenu
        else { return }
        file.addItem(.separator())
        file.addItem(item(for: .exportText))
    }

    /// Theme, appearance, scrolling and the palette, under View. Theme and
    /// appearance share one submenu — they are one daily choice — and a
    /// separate Settings menu would duplicate the app menu's ⌘,.
    private func installViewMenuItems(in mainMenu: NSMenu) {
        guard let view = mainMenu.items.first(where: { $0.title == "View" })?.submenu
        else { return }
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

        let themeItem = NSMenuItem(title: L10n.text("settings.label.theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        view.addItem(themeItem)
    }

    /// Rebuilt from the configuration as the menu opens, so a theme defined
    /// at runtime appears.
    private var themeMenu: NSMenu {
        let menu = NSMenu(title: L10n.text("settings.label.theme"))
        menu.delegate = self
        rebuildThemeMenu(menu)
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
        NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
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
            // Five Find items share `performFindPanelAction:`; match the tag.
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
        if menu.title == AppDelegate.presetMenuTitle {
            rebuildPresetMenu(menu)
            return
        }
        guard menu.title == L10n.text("settings.label.theme") else { return }
        rebuildThemeMenu(menu)
    }
}

#if DEBUG
extension AppDelegate {
    @objc func showSFTPDevelopmentPreview(_ sender: Any?) { SFTPBrowserController.showDevelopmentPreview() }
}
#endif
