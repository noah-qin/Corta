import Cocoa

/// The menu bar: the items the storyboard cannot carry, and the keyboard
/// shortcuts every item's key equivalent is read from (M7.7).
///
/// **Why the shortcuts live here and not in the storyboard.** A key
/// equivalent baked into a nib cannot be changed by a config file, which is
/// what made every shortcut in Corta unrebindable. Menu items are still the
/// dispatch mechanism — that is what makes ⌘D reach the right window's split
/// controller through the responder chain — but their key equivalents are now
/// *applied* from `Keybindings` after the menu exists, and re-applied
/// whenever the config file changes. Nothing intercepts keys behind AppKit's
/// back, and the menus keep showing the shortcut that actually works.
extension AppDelegate {
    /// The Edit menu, so `menuNeedsUpdate` can tell it from the theme menu
    /// without matching on a localized title. Weak: the menu bar owns it.
    fileprivate static weak var editMenu: NSMenu?

    /// Builds the items the storyboard has no place for, then applies the
    /// keyboard shortcuts to every item in the bar.
    func installMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        installAboutItem(in: mainMenu)
        installUpdateItem(in: mainMenu)
        installShellMenuItems(in: mainMenu)
        installViewMenuItems(in: mainMenu)
        installHelpMenuItems(in: mainMenu)
        pruneInapplicableEditItems(in: mainMenu)
        localizeStoryboardMenuTitles(in: mainMenu)
        applyKeybindings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyKeybindings), name: ConfigurationStore.didChange,
            object: nil)
    }

    /// Storyboard menu items are intentionally kept in the base storyboard so
    /// AppKit can wire their responder-chain actions. Their visible titles are
    /// localized after the menu is loaded, which also keeps the menu in sync
    /// with the String Catalog without maintaining nine storyboard copies.
    private func localizeStoryboardMenuTitles(in menu: NSMenu) {
        let titles: [String: String] = [
            "Corta": "menu.corta", "About Corta": "menu.aboutCorta", "Settings…": "command.settings",
            "Services": "menu.services", "Hide Corta": "menu.hideCorta", "Hide Others": "menu.hideOthers",
            "Show All": "menu.showAll", "Quit Corta": "menu.quitCorta", "File": "menu.file",
            "New": "menu.new", "New Tab": "command.newTab", "Close": "command.close",
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
            if let submenu = item.submenu { localizeStoryboardMenuTitles(in: submenu) }
        }
    }

    /// Help > Keyboard Shortcuts (⌘/) — the discoverability surface for
    /// everything that is only reachable by knowing a key or a menu
    /// (`ShortcutsWindowController`). Under Help because that is where a
    /// person looks for "what can this do", and ⌘/ because that is the key
    /// every other app with a shortcut sheet uses.
    private func installHelpMenuItems(in mainMenu: NSMenu) {
        guard let help = mainMenu.items.first(where: { $0.title == "Help" })?.submenu
        else { return }
        let item = NSMenuItem(
            title: L10n.text("shortcuts.title"), action: #selector(showShortcutsWindow(_:)),
            keyEquivalent: "/")
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        help.addItem(.separator())
        help.addItem(item)
    }

    @objc func showShortcutsWindow(_ sender: Any?) {
        ShortcutsWindowController.shared.show(sender)
    }

    /// Removes the Edit-menu items the storyboard template ships that a
    /// self-drawn terminal cannot honour.
    ///
    /// AppKit's Edit menu is written for `NSTextView`: Spelling and Grammar,
    /// Substitutions (smart quotes, smart dashes, text replacement),
    /// Transformations (upper case, lower case, capitalize), Speech, Paste and
    /// Match Style, and Find and Replace all send actions that only a Cocoa
    /// text view implements. Corta's terminal view is a `CAMetalLayer` with a
    /// VT parser behind it: it has no editable text object, no attributed
    /// string, and no notion of replacing a range — the child process owns
    /// every byte on screen. So every one of those items was permanently
    /// greyed out at best, and at worst *not* greyed out and promising an
    /// operation that silently did nothing.
    ///
    /// Find and Replace is the clearest case. `performFindPanelAction:` with
    /// the replace tags reaches `ViewController.performFindPanelAction`, which
    /// handles tags 1, 2, 3 and 7 and drops everything else on the floor — so
    /// the menu made a promise the code had already decided not to keep. A
    /// terminal has nothing to replace: the text is a transcript of output
    /// that has already happened. The item goes rather than gaining a
    /// do-nothing implementation or an alert explaining itself.
    ///
    /// Removed by *action*, not by title, so a localized menu prunes the same
    /// items — and by submenu identity for the three template submenus, whose
    /// parent item carries no action of its own.
    private func pruneInapplicableEditItems(in mainMenu: NSMenu) {
        guard let edit = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu
        else { return }

        // The submenu groups, matched by the actions their children send:
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

        // Paste and Match Style: pasting into a terminal is bytes on a PTY;
        // there is no style to match or to discard.
        let removableActions: Set<Selector> = [
            #selector(NSTextView.pasteAsPlainText(_:))
        ]
        // The Find submenu keeps Find…, Find Next, Find Previous and Use
        // Selection for Find (tags 1, 2, 3 and 7 — see
        // `ViewController.performFindPanelAction`) and loses the rest.
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
        // Removing items can leave a separator at an end or two in a row.
        tidySeparators(in: edit)
        // AppKit injects AutoFill and Start Dictation into the Edit menu
        // *after* this runs, and re-injects them, so they cannot be removed
        // here — see `menuNeedsUpdate`.
        edit.delegate = self
        AppDelegate.editMenu = edit
    }

    /// AutoFill and Start Dictation, dropped as the Edit menu opens.
    ///
    /// AppKit adds these itself, after `installMenus` and again whenever it
    /// feels like it, so a one-time removal does not hold. Both target a
    /// Cocoa text field: AutoFill fills credentials into one, and Dictation
    /// inserts recognised speech into the first responder's text storage —
    /// of which a `CAMetalLayer` has none. Neither has ever done anything in
    /// Corta.
    ///
    /// Emoji & Symbols stays. That one does work: `TerminalView` implements
    /// `NSTextInputClient` for the IME (`TerminalView+IME.swift`), so the
    /// character picker's insertion lands on the grid like any other input.
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
        tidySeparators(in: menu)
    }

    /// Drops leading, trailing and doubled separators — what is left after
    /// items are removed from between them.
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

    /// Points "About Corta" at Corta's own About window.
    ///
    /// Retargeted here rather than rewired in the storyboard, for the same
    /// reason the shortcuts are applied here: the storyboard's version of an
    /// item is a starting point, and the app menu's About item is the one
    /// item a storyboard cannot express — it is created by AppKit's template
    /// with `orderFrontStandardAboutPanel:` already attached.
    ///
    /// Matched by action, not by title: the title is localised by AppKit and
    /// "About Corta" is only what it happens to say in English.
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

    /// "Check for Updates…", directly under About — the position every
    /// Sparkle-using Mac app puts it in, found by habit rather than by
    /// reading the menu. Inserted by index rather than appended, so it
    /// lands next to About even if the app menu template ever grows an
    /// item between them.
    private func installUpdateItem(in mainMenu: NSMenu) {
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

    /// Pane geometry (M7.8) and command-to-command jumping (M7.2), under
    /// Shell where the other pane commands already live.
    private func installShellMenuItems(in mainMenu: NSMenu) {
        guard let shell = mainMenu.items.first(where: { $0.title == "Shell" })?.submenu
        else { return }
        shell.addItem(.separator())
        for command in [
            TerminalCommand.growPaneHorizontally, .shrinkPaneHorizontally,
            .growPaneVertically, .shrinkPaneVertically, .equalizePanes,
        ] {
            shell.addItem(item(for: command))
        }
        shell.addItem(.separator())
        for command in [TerminalCommand.previousCommand, .nextCommand] {
            shell.addItem(item(for: command))
        }
    }

    /// Theme, appearance, scrolling and the command palette, under View.
    ///
    /// The theme and appearance lists used to be a top-level "Settings" menu
    /// of their own, whose first item was a second "Settings…" duplicating
    /// the one macOS puts in the app menu at ⌘, — two entries for one window,
    /// and a menu bar with a Settings menu *and* a Settings item. They belong
    /// in View: they are what the window looks like, which is what View is
    /// for, and the app menu keeps the single Settings entry.
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
        view.addItem(.separator())

        let themeItem = NSMenuItem(title: L10n.text("settings.label.theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        view.addItem(themeItem)

        let appearanceItem = NSMenuItem(title: L10n.text("settings.tab.appearance"), action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: L10n.text("settings.tab.appearance"))
        for (index, appearance) in Configuration.Appearance.allCases.enumerated() {
            let title = appearance == .auto ? L10n.text("settings.appearance.followSystem") : L10n.text("settings.appearance.\(appearance.rawValue)")
            let item = NSMenuItem(
                title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        view.addItem(appearanceItem)
    }

    /// The theme list, rebuilt from the configuration each time the menu is
    /// about to open — the config file can define a theme (M7.6) while the
    /// app is running, and a menu built once at launch would never show it.
    private var themeMenu: NSMenu {
        let menu = NSMenu(title: L10n.text("settings.label.theme"))
        menu.delegate = self
        rebuildThemeMenu(menu)
        return menu
    }

    func rebuildThemeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, theme) in Theme.all(in: ConfigurationStore.shared.configuration).enumerated() {
            let item = NSMenuItem(
                title: theme.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
    }

    private func item(for command: TerminalCommand) -> NSMenuItem {
        // No target: the responder chain resolves it, which is what lets one
        // menu item act on whichever window and pane has focus.
        NSMenuItem(title: command.title, action: command.action, keyEquivalent: "")
    }

    /// Writes every command's shortcut onto whichever menu items carry its
    /// action. Called at launch and on every config change, so unbinding a
    /// key in the file clears it from the menu too.
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
            // `performFindPanelAction:` is shared by five Find items, told
            // apart by tag; only the one this command means may be rebound.
            if let tag = command.menuTag, item.tag != tag { continue }
            item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
            item.keyEquivalentModifierMask = shortcut?.menuModifierMask ?? []
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The theme list is data that can change while the app runs, so it is
    /// rebuilt as the menu opens rather than at launch.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === AppDelegate.editMenu {
            pruneInjectedEditItems(menu)
            return
        }
        guard menu.title == L10n.text("settings.label.theme") else { return }
        rebuildThemeMenu(menu)
    }
}
