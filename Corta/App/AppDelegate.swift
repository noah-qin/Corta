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
import CortaTerminal
import UserNotifications

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The entry point. No nib: the delegate is created here, and builds the
    /// menu bar (`installMenus`) and the first window
    /// (`applicationDidFinishLaunching`) itself. `NSApplication`'s reference
    /// to it is weak, so its lifetime is extended across the run loop
    /// explicitly; a local alone is not guaranteed to live past its last use.
    static func main() {
        // Started by an SFTP connection's ssh as its `SSH_ASKPASS`: carry the
        // question to the running app and exit, before any UI exists.
        if let status = SSHAskpassClient.runIfInvoked() { exit(status) }
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) {
            _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        }
    }

    /// Nothing else retains a window controller, and dropping one takes its
    /// window and session down.
    private var windowControllers: [NSWindowController] = []
    /// The windows an App Intent may name, in opening order.
    var terminalWindowControllers: [TerminalWindowController] {
        windowControllers.compactMap { $0 as? TerminalWindowController }
    }
    /// Every window's tabs, windows in opening order (D30); what an App
    /// Intent calls a window.
    var terminalTabs: [TerminalTab] { terminalWindowControllers.flatMap(\.tabs) }
    /// The debounced arrangement write; see `noteLayoutChanged`.
    var pendingLayoutSave: DispatchWorkItem?
    /// Set at quit, so closing windows don't save an empty arrangement over
    /// the one just flushed.
    private var isTerminating = false
    /// A quit confirmation sheet is up; see `applicationShouldTerminate`.
    private var isAskingToTerminate = false

    /// File > New Window (⌘N).
    @objc func newDocument(_: Any?) {
        openWindow(workingDirectory: nil)
    }

    /// The one route for opening a window (⌘N, Dock click, App Intent).
    /// `workingDirectory` is a spawn cwd, never written to the child's stdin.
    @discardableResult
    func openWindow(workingDirectory: String?) -> TerminalWindowController? {
        let controller = makeWindowController(
            setup: SplitViewController.Setup(workingDirectory: workingDirectory))
        cascade(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Cascades a new window from the key window and keeps it on screen.
    func cascade(_ controller: TerminalWindowController) {
        guard let window = controller.window else { return }
        if let previous = NSApp.keyWindow, previous !== window {
            window.setFrameTopLeftPoint(
                NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        window.setFrame(
            WindowState.Frame(window.frame).onScreen(preferredScreen: window.screen, minimumSize: .zero),
            display: false)
    }

    /// Brings a window forward by identity for the App Intent, activating the
    /// app so it really reaches the front. False if the id is gone.
    @discardableResult
    func focusWindow(id: String) -> Bool {
        guard let tab = terminalTabs.first(where: { $0.id == id }), let controller = tab.controller,
            let window = controller.window
        else { return false }
        controller.selectTab(tab)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is asynchronous. An inactive app otherwise leaves its
        // previous window ahead of the requested one on macOS 27.
        window.orderFrontRegardless()
        return true
    }

    /// File > New Tab (⌘T): a tab of the key window (D30).
    @objc func newTab(_ sender: Any?) {
        newTab(beside: NSApp.keyWindow, sender: sender)
    }

    /// A new tab in `existing`'s group, or a new window without one. The
    /// toolbar's button names its own window: the key window is nil while
    /// Corta is inactive, and the tab would have opened as a window.
    func newTab(beside existing: NSWindow?, sender: Any?) {
        // A tab of the window that asked (D30); with none, a window.
        if let owner = existing?.windowController as? TerminalWindowController {
            owner.addTab()
            owner.window?.makeKeyAndOrderFront(sender)
            return
        }
        let controller = makeWindowController()
        guard let window = controller.window else { return }
        cascade(controller)
        controller.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    /// One tracked terminal window controller, its root pane spawned from
    /// `setup` and its window sized, not yet shown.
    func makeWindowController(
        setup: SplitViewController.Setup = .init()
    ) -> TerminalWindowController {
        let controller = TerminalWindowController(setup: setup)
        track(controller)
        return controller
    }

    /// Retains `controller` until its window closes.
    func track(_ controller: NSWindowController) {
        guard !windowControllers.contains(controller) else { return }
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: controller.window)
        // Moves, resizes and a change of selected tab (the tab's window
        // becomes main) coalesce into one debounced write.
        for name in [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification,
            NSWindow.didBecomeMainNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(noteLayoutChanged), name: name,
                object: controller.window)
        }
        noteLayoutChanged()
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        // Window closes bypass `SplitViewController.closePane`, so tear the
        // sessions and observers down here.
        if windowControllers.contains(where: { $0.window === window }) {
            for split in window.terminalSplits { split.teardown() }
        }
        windowControllers.removeAll { $0.window === window }
        for name in [
            NSWindow.willCloseNotification, NSWindow.didResizeNotification,
            NSWindow.didMoveNotification, NSWindow.didBecomeMainNotification,
        ] {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
        }
        // Not at quit, where the last close would save an empty arrangement.
        if !isTerminating { noteLayoutChanged() }
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(sender)
    }

    @objc func showThemeEditor(_ sender: Any?) { SettingsWindowController.shared.showThemeEditor(sender) }
    @objc func showHostDetails(_ sender: Any?) { SettingsWindowController.shared.showHostDetails(sender) }

    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteController.shared.show(sender)
    }

    // MARK: - System entry points

    /// Writes the config file, the setting's only store; `SecureInput`
    /// follows the file.
    @objc func toggleSecureKeyboardEntry(_: Any?) {
        let turningOn = !ConfigurationStore.shared.configuration.secureKeyboardEntry
        ConfigurationStore.shared.update { $0.secureKeyboardEntry = turningOn }
        // A toast, because the effect itself is invisible.
        let key = turningOn ? "secureInput.toast.on" : "secureInput.toast.off"
        NSApp.keyWindow?.terminalSplit?
            .focusedPane?.terminalView?.showToast(L10n.text(key))
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        let themes = Theme.all(in: ConfigurationStore.shared.configuration)
        guard sender.tag < themes.count else { return }
        ConfigurationStore.shared.update { $0.setTheme(themes[sender.tag].name) }
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        let appearance = Configuration.Appearance.allCases[sender.tag]
        ConfigurationStore.shared.update { $0.appearance = appearance }
    }

    /// Ticks the live theme and appearance as the menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let configuration = ConfigurationStore.shared.configuration
        switch menuItem.action {
        case #selector(selectTheme(_:)):
            let themes = Theme.all(in: configuration)
            menuItem.state =
                menuItem.tag < themes.count
                && themes[menuItem.tag].name == configuration.themeName(dark: AppearanceController.shared.isDark)
                ? .on : .off
        case #selector(selectAppearance(_:)):
            menuItem.state =
                Configuration.Appearance.allCases[menuItem.tag] == configuration.appearance
                ? .on : .off
        case #selector(toggleSecureKeyboardEntry(_:)):
            menuItem.state = configuration.secureKeyboardEntry ? .on : .off
        default:
            break
        }
        return true
    }

    /// Runs before the first window exists, so it opens with the right theme
    /// rather than re-theming a frame later.
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if CORTA_HEADLESS_TESTS
        // Command-line CPU/Metal tests must not activate a window, start a
        // shell or alter secure input on the user's desktop.
        NSApp.setActivationPolicy(.prohibited)
        return
        #endif
        AppPaths.pruneStaleTestStages()
        _ = ConfigurationStore.shared
        _ = UpdateController.shared
        AppearanceController.shared.start()
        // Before any window: Secure Keyboard Entry must see the first window
        // become key.
        SecureInput.shared.start()
        installMenus()
        // Before any window, so a move-and-relaunch never spawns a shell first.
        ApplicationsFolderMover.promptIfNeeded()
    }

    private var stallTimer: Timer?
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DispatchQueue.global(qos: .utility).async { FileDropStorage.removeStale() }
        if let stall = DiagnosticsEnvironment.mainStall() {
            let timer = Timer(timeInterval: stall.periodMilliseconds / 1000, repeats: true) { _ in
                Thread.sleep(forTimeInterval: stall.milliseconds / 1000)
            }
            stallTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        #if CORTA_HEADLESS_TESTS
        return
        #endif
        // Off the main thread: a listing of the temporary directory.
        DispatchQueue.global(qos: .utility).async { ZshBootstrap.removeStaleFolders() }
        // The saved arrangement, or one window; restored windows are born in
        // their saved directories, so no first window is opened to replace.
        if !restoreWindowsIfConfigured() { openWindow(workingDirectory: nil) }
        #if DEBUG
        if CommandLine.arguments.contains("--sftp-preview") { SFTPBrowserController.showDevelopmentPreview() }
        if CommandLine.arguments.contains("--glass-preview") { GlassAppearancePreview.show() }
        if CommandLine.arguments.contains("--tab-preview"), let window = terminalWindowControllers.first?.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak window] in
                guard let self, let window else { return }
                window.terminalSplit?.splitRight(nil)
                self.newTab(beside: window, sender: nil)
                self.newTab(beside: window, sender: nil)
                window.makeKeyAndOrderFront(nil)
            }
        }
        if CommandLine.arguments.contains("--pane-preview"),
           let split = terminalWindowControllers.first?.window?.terminalSplit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                split.splitRight(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { split.splitDown(nil) }
            }
        }
        #endif
        // A notification click jumps back to its command
        // (`AppDelegate+Notifications.swift`).
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Reopening

    /// A Dock click with no window open opens one; Corta keeps running with
    /// no windows, and otherwise there was no way back but ⌘N.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        newDocument(sender)
        return false
    }

}

// MARK: - Restoring the arrangement

extension AppDelegate {

    /// The setting, plus an escape hatch the UI tests set so each launch
    /// doesn't reopen the previous test's windows. A real launch never has it.
    static var isRestoreEnabled: Bool {
        guard !DiagnosticsEnvironment.isWindowRestoreSuppressed() else { return false }
        return ConfigurationStore.shared.configuration.restoreWindows
    }

    /// Reopens last run's windows and splits; false when nothing was.
    private func restoreWindowsIfConfigured() -> Bool {
        guard Self.isRestoreEnabled else { return false }
        let states: [WindowState]
        switch SessionRestore.standard.decideRestore() {
        case .skipAfterFailure:
            // The marker survives only a launch that died mid-restore; that layout
            // is the suspect, so drop it.
            SessionRestore.standard.clear()
            SessionRestore.standard.endRestore()
            return false
        case .nothingToRestore:
            return false
        case .restore(let saved):
            states = saved
        }
        SessionRestore.standard.beginRestore()
        // Keep the state file: `noteLayoutChanged` rewrites it, so a later
        // crash still has a last-known-good layout.
        defer { SessionRestore.standard.endRestore() }

        var opened = 0
        for ordered in Self.restoredWindows(states) {
            guard let first = ordered.first else { continue }
            let controller = makeWindowController(setup: SplitViewController.Setup(restore: first))
            for state in ordered.dropFirst() {
                controller.addTab(setup: SplitViewController.Setup(restore: state), select: false)
            }
            // Every tab's splits now, while each is still laid out at the
            // window's frame; a tab hidden behind the selected one would
            // otherwise wait until it is first shown.
            for tab in controller.tabs { tab.split.applyPendingRestore() }
            if let selected = ordered.firstIndex(where: \.isSelectedTab), ordered.count > 1 {
                controller.selectTab(controller.tabs[selected])
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            opened += 1
        }
        return opened > 0
    }

    /// Saved states as windows, each its tabs in saved order (D30): one
    /// window per tab group, in the order its first tab was saved; a state
    /// with no group is a window of its own.
    ///
    /// A group is its identity and its frame together. Arrangements saved
    /// with macOS's own tabs gave every group the same identity — the
    /// windows' shared `tabbingIdentifier` — and only the frame, which
    /// every tab of one window shares, tells two of those windows apart.
    static func restoredWindows(_ states: [WindowState]) -> [[WindowState]] {
        var windows: [[WindowState]] = []
        var groupIndex: [String: Int] = [:]
        for state in states {
            let frame = state.frame
            let key = state.tabGroupID.map { "\($0)|\(frame.x),\(frame.y),\(frame.width),\(frame.height)" }
            if let key, let index = groupIndex[key] {
                windows[index].append(state)
            } else {
                if let key { groupIndex[key] = windows.count }
                windows.append([state])
            }
        }
        return windows.map { members in members.sorted { ($0.tabIndex ?? 0) < ($1.tabIndex ?? 0) } }
    }

    private func saveWindowStates() {
        guard Self.isRestoreEnabled else {
            SessionRestore.standard.clear()
            return
        }
        SessionRestore.standard.save(
            windowControllers.flatMap { ($0 as? TerminalWindowController)?.restorableStates ?? [] })
    }

    // MARK: - Keeping the arrangement current

    /// The quiet time before the arrangement is written: a drag is one write,
    /// and a crash loses at most the last gesture.
    private static let layoutSaveDelay: TimeInterval = 0.5

    /// Schedules a debounced write. Saving only at quit lost everything on a
    /// crash — the case restore exists for.
    @objc func noteLayoutChanged() {
        guard Self.isRestoreEnabled else { return }
        pendingLayoutSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingLayoutSave = nil
            self.saveWindowStates()
        }
        pendingLayoutSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutSaveDelay, execute: item)
    }

    /// Writes a pending arrangement now, at quit.
    private func flushLayoutSave() {
        pendingLayoutSave?.cancel()
        pendingLayoutSave = nil
        saveWindowStates()
    }

    /// Confirms ⌘Q with something running; quitting bypasses
    /// `windowShouldClose`. A sheet on the key terminal window (or the first
    /// visible one), answered later; app-modal, answered now, when none is
    /// visible.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = windowControllers.flatMap { $0.window?.terminalSplits ?? [] }
            .flatMap(\.panes).filter { $0.session?.hasForegroundJob == true }
        guard let split = windowControllers.first?.window?.terminalSplit,
            split.needsCloseConfirmation(for: running)
        else { return .terminateNow }
        // Already asking: that sheet answers this quit too.
        guard !isAskingToTerminate else { return .terminateCancel }
        // Only terminal windows with room to present a confirmation sheet.
        let windows = windowControllers.compactMap { controller -> NSWindow? in
            guard let terminal = controller as? TerminalWindowController
            else { return nil }
            return terminal.window
        }.filter { NSAlert.canPresentSheet(on: $0) }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
            let presenter = window.terminalSplit
        else {
            let alert = split.closeAlert(for: running, scope: L10n.text("close.scope.app"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        isAskingToTerminate = true
        presenter.confirmClose(of: running, scope: L10n.text("close.scope.app"), in: window) { [weak self] in
            self?.isAskingToTerminate = false
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        stallTimer?.invalidate()
        stallTimer = nil
        isTerminating = true
        flushLayoutSave()
        DirectoryHistoryStore.shared.flush()
        ZshBootstrap.removeGeneratedFiles()
        // The askpass socket and its directory.
        SSHAskpassBroker.shared.stop()
        // The secure-input count must reach zero before exit.
        SecureInput.shared.disengage()
        // Not every quit path reaches `windowWillClose`; tear down explicitly
        // rather than leave children to SIGHUP.
        for controller in windowControllers {
            for split in controller.window?.terminalSplits ?? [] { split.teardown() }
        }
    }

    /// AppKit restoration is off: a live process isn't a document.
    /// `SessionRestore` saves the arrangement instead.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
}
