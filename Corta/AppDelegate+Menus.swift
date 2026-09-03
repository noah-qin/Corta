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
    /// Builds the items the storyboard has no place for, then applies the
    /// keyboard shortcuts to every item in the bar.
    func installMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        installShellMenuItems(in: mainMenu)
        installViewMenuItems(in: mainMenu)
        applyKeybindings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyKeybindings), name: ConfigurationStore.didChange,
            object: nil)
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

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        view.addItem(themeItem)

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for (index, appearance) in Configuration.Appearance.allCases.enumerated() {
            let title = appearance == .auto ? "Follow System" : appearance.rawValue.capitalized
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
        let menu = NSMenu(title: "Theme")
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
        guard menu.title == "Theme" else { return }
        rebuildThemeMenu(menu)
    }
}
