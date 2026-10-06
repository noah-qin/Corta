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
import CortaSFTP
import CortaTerminal
import UserNotifications

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    /// Nothing else retains a window controller, and dropping one takes its
    /// window and session down.
    private var windowControllers: [NSWindowController] = []
    /// The windows an App Intent may name, in opening order; the Quick
    /// Terminal has its own intent.
    var terminalWindowControllers: [TerminalWindowController] {
        windowControllers.compactMap { $0 as? TerminalWindowController }.filter { !$0.isQuickTerminal }
    }
    /// The debounced arrangement write; see `noteLayoutChanged`.
    var pendingLayoutSave: DispatchWorkItem?
    /// Set at quit, so closing windows don't save an empty arrangement over
    /// the one just flushed.
    private var isTerminating = false

    /// File > New Window (⌘N).
    @objc func newDocument(_ sender: Any?) {
        openWindow(workingDirectory: nil)
    }

    /// The one route for opening a window (⌘N, Dock click, App Intent).
    /// `workingDirectory` is a spawn cwd, never written to the child's stdin.
    @discardableResult
    func openWindow(workingDirectory: String?) -> TerminalWindowController? {
        guard
            let controller = instantiateWindowController(
                setup: SplitViewController.Setup(workingDirectory: workingDirectory))
                as? TerminalWindowController
        else { return nil }
        // Cascade from the opening window, or ⌘N looks like it did nothing —
        // except from the Quick Terminal's screen-edge band.
        if let previous = NSApp.keyWindow, let window = controller.window,
            !QuickTerminalController.shared.owns(previous)
        {
            window.setFrameTopLeftPoint(
                NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        if let window = controller.window, window.tabbedWindows == nil {
            window.setFrame(WindowState.Frame(window.frame).onScreen(preferredScreen: window.screen, minimumSize: .zero), display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Brings a window forward by identity for the App Intent, activating the
    /// app so it really reaches the front. False if the id is gone.
    @discardableResult
    func focusWindow(id: String) -> Bool {
        guard let controller = terminalWindowControllers.first(where: { $0.windowID == id }),
            let window = controller.window
        else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// File > New Tab (⌘T): a full window joined to the key window's tab
    /// group, so it can be dragged out again.
    @objc func newTab(_ sender: Any?) {
        let existing = NSApp.keyWindow
        guard let controller = instantiateWindowController(),
            let window = controller.window else { return }
        window.tabbingMode = .automatic
        if let keyWindow = existing, keyWindow !== window,
            !QuickTerminalController.shared.owns(keyWindow),
            keyWindow.contentViewController is SplitViewController {
            let members = keyWindow.tabbedWindows ?? [keyWindow]
            let frame = keyWindow.frame
            let oldChrome = frame.height - keyWindow.contentLayoutRect.height
            let splits = (members + [window]).compactMap { $0.contentViewController as? SplitViewController }
            for split in splits { split.isJoiningTabGroup = true }
            window.setFrame(frame, display: false)
            keyWindow.addTabbedWindow(window, ordered: .above)
            controller.showWindow(sender)
            window.makeKeyAndOrderFront(sender)
            // Only the first tab bar adds chrome. New tabs' setup/layout must
            // not each absorb the same bar into the shared frame again.
            let delta = members.count == 1
                ? max(0, window.frame.height - window.contentLayoutRect.height - oldChrome) : 0
            var target = frame
            target.origin.y -= delta
            target.size.height += delta
            window.setFrame(target, display: true)
            for split in splits {
                split.adoptChromeWithoutAbsorbing()
                split.isJoiningTabGroup = false
            }
        } else {
            controller.showWindow(sender)
            window.makeKeyAndOrderFront(sender)
        }
    }

    /// The tab bar's "+" button; implementing this is also what shows it.
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    /// One tracked storyboard window controller. `setup` reaches the root
    /// pane before it spawns (D16, `SplitViewController.pendingSetup`).
    /// `asPanel` swaps in a non-activating panel for the Quick Terminal
    /// (`TerminalWindowController.adoptNonactivatingPanel`).
    func instantiateWindowController(
        setup: SplitViewController.Setup? = nil, asPanel: Bool = false
    ) -> NSWindowController? {
        SplitViewController.pendingSetup = setup
        defer { SplitViewController.pendingSetup = nil }
        guard let controller = NSStoryboard(name: "Main", bundle: nil)
            .instantiateInitialController() as? NSWindowController
        else { return nil }
        if asPanel { (controller as? TerminalWindowController)?.adoptNonactivatingPanel() }
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
        // Moves and resizes coalesce into one debounced write.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
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
        if let controller = windowControllers.first(where: { $0.window === window }) {
            (controller.contentViewController as? SplitViewController)?.teardown()
        }
        windowControllers.removeAll { $0.window === window }
        for name in [
            NSWindow.willCloseNotification, NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
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

    /// Menu, palette and App Intent; the hotkey calls
    /// `QuickTerminalController.toggle` directly.
    @objc func toggleQuickTerminal(_ sender: Any?) {
        QuickTerminalController.shared.toggle()
    }

    /// Writes the config file, the setting's only store; `SecureInput`
    /// follows the file.
    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        let turningOn = !ConfigurationStore.shared.configuration.secureKeyboardEntry
        ConfigurationStore.shared.update { $0.secureKeyboardEntry = turningOn }
        // A toast, because the effect itself is invisible.
        let key = turningOn ? "secureInput.toast.on" : "secureInput.toast.off"
        (NSApp.keyWindow?.contentViewController as? SplitViewController)?
            .focusedPane?.terminalView?.showToast(L10n.text(key))
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

    /// Ticks the live theme and appearance as the menu opens.
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
        AppPaths.pruneStaleTestStages()
        _ = ConfigurationStore.shared
        _ = UpdateController.shared
        AppearanceController.shared.start()
        // Before any window: the hotkey must be held from launch, and Secure
        // Keyboard Entry must see the first window become key.
        SecureInput.shared.start()
        QuickTerminalController.shared.start()
        installMenus()
        // Before any window, so a move-and-relaunch never spawns a shell first.
        ApplicationsFolderMover.promptIfNeeded()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Track the storyboard's first window like any ⌘N window.
        for window in NSApp.windows {
            if let controller = window.windowController {
                track(controller)
            }
        }
        restoreWindowsIfConfigured()
        #if DEBUG
        if CommandLine.arguments.contains("--sftp-preview") { SFTPBrowserController.showDevelopmentPreview() }
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

    // MARK: - Restoring the arrangement

    /// The setting, plus an escape hatch the UI tests set so each launch
    /// doesn't reopen the previous test's windows. A real launch never has it.
    static var isRestoreEnabled: Bool {
        guard !DiagnosticsEnvironment.isWindowRestoreSuppressed() else { return false }
        return ConfigurationStore.shared.configuration.restoreWindows
    }

    /// Reopens last run's windows and splits.
    private func restoreWindowsIfConfigured() {
        guard Self.isRestoreEnabled else { return }
        let states: [WindowState]
        switch SessionRestore.standard.decideRestore() {
        case .skipAfterFailure:
            // The marker survives only a launch that died mid-restore; that layout
            // is the suspect, so drop it.
            SessionRestore.standard.clear()
            SessionRestore.standard.endRestore()
            return
        case .nothingToRestore:
            return
        case .restore(let saved):
            states = saved
        }
        SessionRestore.standard.beginRestore()
        // Keep the state file: `noteLayoutChanged` rewrites it, so a later
        // crash still has a last-known-good layout.
        defer { SessionRestore.standard.endRestore() }

        // The storyboard's window already spawned its shell in the home
        // directory, which a restore can't move. Every saved state gets a fresh
        // window with `pendingRestore` staged before its view loads, and the
        // pre-opened one closes once a replacement is up.
        let preopened = windowControllers.first
        var restored: [(state: WindowState, controller: NSWindowController)] = []
        for state in states {
            // Staged before the view loads (D16).
            guard
                let controller = instantiateWindowController(
                    setup: SplitViewController.Setup(restore: state))
            else { continue }
            // Keep the saved identity for intents resolved last run.
            if let id = state.id, let terminal = controller as? TerminalWindowController {
                terminal.windowID = id
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            restored.append((state, controller))
        }
        // Only if replaced; never leave the app with no window.
        if !restored.isEmpty, let preopened, preopened.window?.isVisible == true {
            preopened.window?.close()
        }
        regroupRestoredTabs(restored)
    }

    /// Regroups restored windows by `tabGroupID`, in saved order, reselecting
    /// the frontmost. Groups of one are left alone.
    func regroupRestoredTabs(
        _ restored: [(state: WindowState, controller: NSWindowController)]
    ) {
        let byGroup = Dictionary(grouping: restored.filter { $0.state.tabGroupID != nil }) {
            $0.state.tabGroupID!
        }
        for (_, members) in byGroup {
            guard members.count > 1 else { continue }
            let ordered = members.sorted { ($0.state.tabIndex ?? 0) < ($1.state.tabIndex ?? 0) }
            guard var previous = ordered.first?.controller.window else { continue }
            // Add each tab after the previous one: `.above` inserts right after the
            // receiver, so adding to the first reversed the order.
            for member in ordered.dropFirst() {
                guard let window = member.controller.window else { continue }
                previous.addTabbedWindow(window, ordered: .above)
                previous = window
            }
            if let selected = ordered.first(where: { $0.state.isSelectedTab })?.controller.window {
                selected.makeKeyAndOrderFront(nil)
            }
            // Only the selected window lays out on its own, and the saved frames
            // already include the tab bar (`adoptChromeWithoutAbsorbing`).
            for member in ordered {
                (member.controller.contentViewController as? SplitViewController)?
                    .adoptChromeWithoutAbsorbing()
            }
        }
    }

    private func saveWindowStates() {
        guard Self.isRestoreEnabled else {
            SessionRestore.standard.clear()
            return
        }
        SessionRestore.standard.save(
            windowControllers.compactMap { ($0 as? TerminalWindowController)?.restorableState })
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
        let running = windowControllers.compactMap {
            ($0.contentViewController as? SplitViewController)
        }.flatMap(\.panesWithRunningJobs)
        guard let split = windowControllers.first?.contentViewController as? SplitViewController,
            split.needsCloseConfirmation(for: running)
        else { return .terminateNow }
        let windows = windowControllers.compactMap(\.window).filter {
            $0.isVisible && !$0.isMiniaturized && $0.contentViewController is SplitViewController
        }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
            let presenter = window.contentViewController as? SplitViewController
        else {
            let alert = split.closeAlert(for: running, scope: L10n.text("close.scope.app"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        presenter.confirmClose(of: running, scope: L10n.text("close.scope.app"), in: window) {
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        isTerminating = true
        flushLayoutSave()
        DirectoryHistoryStore.shared.flush()
        ZshBootstrap.removeGeneratedFiles()
        // The secure-input count must reach zero before exit.
        SecureInput.shared.disengage()
        QuickTerminalController.shared.teardown()
        // Not every quit path reaches `windowWillClose`; tear down explicitly
        // rather than leave children to SIGHUP.
        for controller in windowControllers {
            (controller.contentViewController as? SplitViewController)?.teardown()
        }
    }

    /// AppKit restoration is off: a live process isn't a document.
    /// `SessionRestore` saves the arrangement instead.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
}
