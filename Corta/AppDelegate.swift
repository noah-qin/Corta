//
//  AppDelegate.swift
//  Corta
//
//  Created by Noah on 9/1/26.
//

import Cocoa
import CortaTerminal

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    /// Strong references to every open terminal window's controller —
    /// nothing else retains a window controller, and a deallocated
    /// controller takes its window (and its session) down with it.
    private var windowControllers: [NSWindowController] = []

    /// File > New (⌘N), wired in the storyboard to First Responder. Each
    /// window is its own `SplitViewController` composing one or more
    /// panes — each pane a `ViewController` with its own
    /// `TerminalSession` — so a new window is composition, not new
    /// mechanism (`DESIGN.md` §2.4).
    @objc func newDocument(_ sender: Any?) {
        guard let controller = instantiateWindowController() else { return }
        // Offset from the window it was opened from. Placed at the same
        // origin the new window is invisible behind the old one, and ⌘N
        // looks like it did nothing.
        if let previous = NSApp.keyWindow, let window = controller.window {
            window.setFrameTopLeftPoint(
                NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    /// File > New Tab (⌘T, M4.7): native window tabbing. The new session is
    /// a full window of its own, added to the key window's tab group — so a
    /// tab can always be dragged out into a standalone window again, and
    /// ⌘N keeps meaning "new window".
    @objc func newTab(_ sender: Any?) {
        guard let controller = instantiateWindowController(),
            let window = controller.window
        else { return }
        window.tabbingMode = .automatic
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            // Join at the group's size: being born at the default size and
            // then resized by the tab group reads as a flash.
            window.setFrame(keyWindow.frame, display: false)
            keyWindow.addTabbedWindow(window, ordered: .above)
            // The tab bar appearing grows the chrome, and AppKit answers by
            // shrinking the content area — every pane in the group silently
            // loses the bar's worth of rows. The key window absorbs that
            // delta into its frame instead; it has to be told, because it is
            // the window the new tab covers and it never lays out again.
            (keyWindow.contentViewController as? SplitViewController)?
                .absorbChromeChange()
        }
        controller.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    /// The tab bar's "+" button sends this through the responder chain;
    /// with no implementor in the chain AppKit does not show the button at
    /// all, so this is also what makes the button appear.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    /// One storyboard window controller, tracked so it lives as long as its
    /// window does.
    private func instantiateWindowController() -> NSWindowController? {
        guard let controller = NSStoryboard(name: "Main", bundle: nil)
            .instantiateInitialController() as? NSWindowController
        else { return nil }
        track(controller)
        return controller
    }

    /// Retains `controller` until its window closes, so the array does not
    /// grow without bound and no open window loses its controller.
    private func track(_ controller: NSWindowController) {
        guard !windowControllers.contains(controller) else { return }
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: controller.window)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - Settings (M6.1)

    /// ⌘, from the app menu, and the Settings menu's own item.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(sender)
    }

    /// The settings menu sits in the menu bar beside Shell and Edit, and is
    /// built here rather than in the storyboard because two of its three
    /// sections are lists of values that live in code — the built-in themes
    /// and the appearance choices. A storyboard copy of either would be a
    /// second place to update.
    private func installSettingsMenu() {
        guard let mainMenu = NSApp.mainMenu,
            let shellIndex = mainMenu.items.firstIndex(where: { $0.title == "Shell" })
        else { return }

        let menu = NSMenu(title: "Settings")
        menu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        for (index, theme) in Theme.builtIn.enumerated() {
            let item = NSMenuItem(
                title: theme.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

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
        menu.addItem(appearanceItem)

        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.insertItem(item, at: shellIndex + 1)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        let theme = Theme.builtIn[sender.tag]
        ConfigurationStore.shared.update { $0.theme = theme.name }
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        let appearance = Configuration.Appearance.allCases[sender.tag]
        ConfigurationStore.shared.update { $0.appearance = appearance }
    }

    /// Ticks the live theme and appearance. `NSMenuValidation` runs just
    /// before a menu opens, which is the only moment the state has to be
    /// right — and it stays right when the config file changes underneath.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let configuration = ConfigurationStore.shared.configuration
        switch menuItem.action {
        case #selector(selectTheme(_:)):
            menuItem.state = Theme.builtIn[menuItem.tag].name == configuration.theme ? .on : .off
        case #selector(selectAppearance(_:)):
            menuItem.state =
                Configuration.Appearance.allCases[menuItem.tag] == configuration.appearance
                ? .on : .off
        default:
            break
        }
        return true
    }

    /// Before the storyboard's first window exists — the first pane reads
    /// the configuration as it loads and draws with the theme's live
    /// variant, so both have to be resolved by then or the window opens in
    /// the default colours and visibly re-themes a frame later.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = ConfigurationStore.shared
        AppearanceController.shared.start()
        installSettingsMenu()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The storyboard's initial window controller shows the first window;
        // nothing retains it either, so track it like the ⌘N windows.
        for window in NSApp.windows {
            if let controller = window.windowController {
                track(controller)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}
