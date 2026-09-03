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

    /// M7.12 — the command palette (⇧⌘P by default).
    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteController.shared.show(sender)
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        let themes = Theme.all(in: ConfigurationStore.shared.configuration)
        guard sender.tag < themes.count else { return }
        ConfigurationStore.shared.update { $0.theme = themes[sender.tag].name }
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
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
            let themes = Theme.all(in: configuration)
            menuItem.state =
                menuItem.tag < themes.count && themes[menuItem.tag].name == configuration.theme
                ? .on : .off
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
        _ = UpdateController.shared
        AppearanceController.shared.start()
        installMenus()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The storyboard's initial window controller shows the first window;
        // nothing retains it either, so track it like the ⌘N windows.
        for window in NSApp.windows {
            if let controller = window.windowController {
                track(controller)
            }
        }
        restoreWindowsIfConfigured()
    }

    // MARK: - Reopening (M7.3)

    /// Clicking the Dock icon with no window open.
    ///
    /// Corta keeps running with its last window closed — a terminal that
    /// quits when you close a window loses whatever else it was hosting — but
    /// without this it kept running with *no way back*: the Dock click did
    /// nothing at all, and ⌘N was the only route to a window. That is the
    /// worst of both designs. AppKit asks this exact question; the answer is
    /// simply "open one".
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        newDocument(sender)
        return false
    }

    // MARK: - Restoring the arrangement (M7.4)

    /// The setting, plus an environment escape hatch for the UI tests.
    ///
    /// A UI test launches, does something, and is killed; the next test then
    /// launches into whatever the previous one left behind, which for a
    /// feature whose whole job is "reopen last time's windows" means every
    /// window-count assertion in the suite depends on test order. The escape
    /// hatch is one variable the tests set, not a behaviour change: a real
    /// launch never has it.
    static var isRestoreEnabled: Bool {
        guard ProcessInfo.processInfo.environment["CORTA_RESTORE_WINDOWS"] != "0" else {
            return false
        }
        return ConfigurationStore.shared.configuration.restoreWindows
    }

    /// Reopens the windows and splits from the last run. The storyboard has
    /// already opened one window by this point, so the first saved state is
    /// applied to *that* window and the rest get windows of their own —
    /// otherwise a restore would always leave one empty extra window behind.
    private func restoreWindowsIfConfigured() {
        guard Self.isRestoreEnabled else { return }
        let states = SessionRestore.load()
        guard !states.isEmpty else { return }
        // Consumed on launch: a crash mid-restore must not replay the same
        // state forever, and the file is rewritten at the next quit anyway.
        SessionRestore.clear()

        // The storyboard's window is already on screen, which means its root
        // pane has already spawned a shell — in the home directory, because
        // nothing had told it otherwise yet. That is the one thing a restore
        // cannot repair afterwards: setting the pane's directory now would
        // relabel it while leaving the child process where it started, so the
        // first restored window used to be the only one that came back in the
        // wrong place. Every saved state therefore gets a window built from
        // scratch, with `pendingRestore` in place before `viewDidLoad`, and
        // the pre-opened one is closed once at least one replacement is up.
        //
        // `contentViewController` returns the controller without loading its
        // view; the view (and with it the pane's session) loads at
        // `showWindow`, after `pendingRestore` has been set.
        let preopened = windowControllers.first
        var restored = 0
        for state in states {
            guard let controller = instantiateWindowController(),
                let split = controller.contentViewController as? SplitViewController
            else { continue }
            // Before the view loads: the root pane needs its working
            // directory at spawn time.
            split.pendingRestore = state
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            restored += 1
        }
        // Only if something replaced it — closing the sole window on a failed
        // restore would leave the app running with nothing on screen.
        if restored > 0, let preopened, preopened.window?.isVisible == true {
            preopened.window?.close()
        }
    }

    private func saveWindowStates() {
        guard Self.isRestoreEnabled else {
            SessionRestore.clear()
            return
        }
        SessionRestore.save(
            windowControllers.compactMap { ($0 as? TerminalWindowController)?.restorableState })
    }

    /// ⌘Q with something still running. `windowShouldClose` covers closing a
    /// window; quitting bypasses it entirely, and losing a build to a
    /// mistyped ⌘Q is exactly the case the confirmation exists for (M7.5).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = windowControllers.compactMap {
            ($0.contentViewController as? SplitViewController)
        }.flatMap(\.panesWithRunningJobs)
        guard let split = windowControllers.first?.contentViewController as? SplitViewController,
            !running.isEmpty
        else { return .terminateNow }
        return split.confirmClose(of: running, scope: "Corta") ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        saveWindowStates()
    }

    /// False: a terminal window has nothing to restore through AppKit's own
    /// mechanism — its content is a live child process, not a document — and
    /// `SplitViewController` already turns `isRestorable` off per window for
    /// that reason. Corta saves and reopens the *arrangement* itself
    /// (`SessionRestore`), which is the part that is actually meaningful.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
}
