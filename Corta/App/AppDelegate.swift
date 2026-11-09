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
    private let layoutWrites = DispatchQueue(label: "Corta.WindowLayout", qos: .utility)
    private var layoutPersistenceSuspended = false
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
        guard saveFromMenu({ $0.secureKeyboardEntry = turningOn }) else { return }
        // A toast, because the effect itself is invisible.
        let key = turningOn ? "secureInput.toast.on" : "secureInput.toast.off"
        NSApp.keyWindow?.terminalSplit?
            .focusedPane?.terminalView?.showToast(L10n.text(key))
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        let themes = Theme.all(in: ConfigurationStore.shared.configuration)
        guard sender.tag < themes.count else { return }
        saveFromMenu { $0.setTheme(themes[sender.tag].name) }
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        let appearance = Configuration.Appearance.allCases[sender.tag]
        saveFromMenu { $0.appearance = appearance }
    }

    @objc func nextWaitingPane(_: Any?) { AgentDirectory.jumpToNextWaitingPane() }

    /// Ticks the live theme and appearance as the menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let configuration = ConfigurationStore.shared.configuration
        switch menuItem.action {
        case #selector(nextWaitingPane(_:)):
            return AgentDirectory.canJumpToNextWaitingPane
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
    /// Saved windows are about to open (`openInitialWindows`).
    var isWaitingForRestore = false
    func applicationDidFinishLaunching(_ aNotification: Notification) {
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
        DispatchQueue.global(qos: .utility).async { FileDropStorage.cleanUpAtLaunch() }
        DispatchQueue.global(qos: .utility).async {
            let stranded = AppPaths.removeAbandonedStateFiles()
            guard !stranded.isEmpty else { return }
            Task { @MainActor [weak self] in self?.reportStrandedExports(stranded) }
        }
        DispatchQueue.global(qos: .utility).async { SSHAskpassBroker.pruneAbandoned() }
        openInitialWindows()
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
        guard !hasVisibleWindows, !isWaitingForRestore else { return true }
        newDocument(sender)
        return false
    }

}

// MARK: - Restoring the arrangement

extension AppDelegate {

    /// The saved arrangement, or one window; restored windows are born in
    /// their saved directories, so no first window is opened to replace. The
    /// directories are checked off the main thread first: one on a mount that
    /// stopped answering held the whole launch. Local ones answer before the
    /// next pass of the run loop.
    func openInitialWindows() {
        guard Self.isRestoreEnabled else {
            openWindow(workingDirectory: nil)
            finishOpeningInitialWindows()
            return
        }
        let store = SessionRestore.standard
        isWaitingForRestore = true
        PathProbe.run { [weak self] in
            let decision = PathProbe.answer(timeout: SessionRestore.directoryCheckTimeout) {
                try? store.readRestoreDecision()
            } ?? nil
            Task { @MainActor [weak self] in self?.finishInitialRestore(decision, store: store) }
        }
    }

    private func finishInitialRestore(_ decision: SessionRestore.RestoreDecision?, store: SessionRestore) {
        switch decision {
        case nil:
            // Unknown, not empty: saving now could write a fresh window over
            // an arrangement nobody could read. Held until the file answers.
            layoutPersistenceSuspended = true
            openFreshInitialWindow()
            rereadRestoreDecision(store: store, attempt: 1)
        case .skipAfterFailure:
            layoutPersistenceSuspended = true
            let controller = openFreshInitialWindow()
            layoutWrites.async { [weak self, weak controller] in
                let archived = (try? store.setAsideFailedRestore()) != nil
                Task { @MainActor [weak self, weak controller] in
                    guard let self else { return }
                    self.layoutPersistenceSuspended = !archived
                    self.noteLayoutChanged()
                    guard let window = controller?.window, window.isVisible else { return }
                    let alert = NSAlert()
                    alert.messageText = L10n.text("restore.failed.title")
                    let message = archived ? "restore.failed.archived" : "restore.failed.preserved"
                    let path = archived ? store.failedRestoreURL.path : store.fileURL.path
                    alert.informativeText = L10n.format(message, path)
                    alert.present(for: window) { _ in }
                }
            }
        case .nothingToRestore:
            openFreshInitialWindow()
        case .restore(let saved):
            PathProbe.directories(
                among: saved.flatMap { $0.layout.validated().directories },
                timeout: SessionRestore.directoryCheckTimeout
            ) { [weak self] existing in
                guard let self else { return }
                let states = SessionRestore.droppingMissingDirectories(saved, existing: existing)
                self.layoutWrites.async { [weak self] in
                    store.beginRestore()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isWaitingForRestore = false
                        if !self.restoreWindows(states) { self.openWindow(workingDirectory: nil) }
                        self.layoutWrites.async { store.endRestore() }
                        self.finishOpeningInitialWindows()
                    }
                }
            }
        }
    }

    /// What a launch whose saved arrangement could not be read does once
    /// a later read answers.
    enum LayoutPersistenceResumption: Equatable {
        /// Still unknown: ask again later.
        case retry
        /// No arrangement on disk: this launch's may be written.
        case resume
        /// An arrangement this launch did not open: set aside, as a failed
        /// restore's is, before this launch's is written in its place.
        case setAsideThenResume
    }

    static func layoutPersistenceResumption(
        after decision: SessionRestore.RestoreDecision?
    ) -> LayoutPersistenceResumption {
        switch decision {
        case nil: .retry
        case .nothingToRestore: .resume
        case .restore, .skipAfterFailure: .setAsideThenResume
        }
    }

    /// Reads attempted after a launch read nothing, before saving stays off
    /// for the rest of the run.
    static let restoreDecisionRereads = 6
    static let restoreDecisionRereadDelay: TimeInterval = 10

    /// The arrangement could not be read at launch (a mount that stopped
    /// answering, a file the read refused): saving stayed off for the whole
    /// run. It is read again, a few times, off the main thread; once its
    /// state is known saving resumes.
    private func rereadRestoreDecision(store: SessionRestore, attempt: Int) {
        guard attempt <= Self.restoreDecisionRereads else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDecisionRereadDelay) { [weak self] in
            guard self != nil else { return }
            PathProbe.run { [weak self] in
                let decision = PathProbe.answer(timeout: SessionRestore.directoryCheckTimeout) {
                    try? store.readRestoreDecision()
                } ?? nil
                Task { @MainActor [weak self] in
                    self?.resumeLayoutPersistence(after: decision, store: store, attempt: attempt)
                }
            }
        }
    }

    private func resumeLayoutPersistence(
        after decision: SessionRestore.RestoreDecision?, store: SessionRestore, attempt: Int
    ) {
        guard layoutPersistenceSuspended else { return }
        switch Self.layoutPersistenceResumption(after: decision) {
        case .retry:
            rereadRestoreDecision(store: store, attempt: attempt + 1)
        case .resume:
            layoutPersistenceSuspended = false
            noteLayoutChanged()
        case .setAsideThenResume:
            layoutWrites.async { [weak self] in
                let archived = (try? store.setAsideFailedRestore()) != nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if archived {
                        self.layoutPersistenceSuspended = false
                        self.noteLayoutChanged()
                    } else {
                        self.rereadRestoreDecision(store: store, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    @discardableResult
    private func openFreshInitialWindow() -> TerminalWindowController? {
        isWaitingForRestore = false
        let controller = openWindow(workingDirectory: nil)
        finishOpeningInitialWindows()
        return controller
    }

    /// What a launch does once its first windows are up.
    private func finishOpeningInitialWindows() {
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
    }

    /// The setting, plus an escape hatch the UI tests set so each launch
    /// doesn't reopen the previous test's windows. A real launch never has it.
    static var isRestoreEnabled: Bool {
        guard !DiagnosticsEnvironment.isWindowRestoreSuppressed() else { return false }
        return ConfigurationStore.shared.configuration.restoreWindows
    }

    /// Reopens these windows and splits; false when nothing was. Their
    /// directories have been checked, so no pane checks one again at its spawn.
    private func restoreWindows(_ states: [WindowState]) -> Bool {
        var opened = 0
        for ordered in Self.restoredWindows(states) {
            guard let first = ordered.first else { continue }
            let controller = makeWindowController(
                setup: SplitViewController.Setup(restore: first, directoriesChecked: true))
            for state in ordered.dropFirst() {
                controller.addTab(
                    setup: SplitViewController.Setup(restore: state, directoriesChecked: true), select: false)
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

    private func saveWindowStates(completion: DispatchGroup? = nil) {
        guard !layoutPersistenceSuspended, !isWaitingForRestore else { return }
        let store = SessionRestore.standard
        guard Self.isRestoreEnabled else {
            layoutWrites.async(group: completion) { store.clear() }
            return
        }
        let states = terminalWindowControllers.flatMap(\.restorableStates)
        layoutWrites.async(group: completion) { store.save(states) }
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


    /// Confirms ⌘Q with something running; quitting bypasses
    /// `windowShouldClose`. A sheet on the key terminal window (or the first
    /// visible one), answered later; app-modal, answered now, when none is
    /// visible.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // On the way out AppKit resolves what this app still promises on any
        // pasteboard, and a dragged SFTP row's file is a promise nobody can keep
        // by then: that wait never ended, and the app never quit. Dropping the
        // promise costs nothing if the quit is cancelled: its drag is over.
        NSPasteboard(name: .drag).clearContents()
        let running = windowControllers.flatMap { $0.window?.terminalSplits ?? [] }
            .flatMap(\.panes).filter(\.hasSessionRequiringCloseConfirmation)
        guard let split = windowControllers.first?.window?.terminalSplit,
            split.needsCloseConfirmation(for: running)
        else { return .terminateNow }
        // Already asking: that sheet answers this quit too.
        guard !isAskingToTerminate else { return .terminateCancel }
        // A window is already asking whether to close what runs in it: a
        // second, app-wide question on top would ask the same thing twice.
        // Its sheet comes forward and answers first.
        if let asking = Self.windowAskingToClose(among: windowControllers.compactMap(\.window)) {
            NSApp.activate()
            asking.makeKeyAndOrderFront(nil)
            asking.attachedSheet?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
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

    /// Once: the record is gone after this, so the same folder is not named
    /// again.
    private func reportStrandedExports(_ folders: [String]) {
        let alert = NSAlert()
        alert.messageText = L10n.text("export.stranded.title")
        alert.informativeText = L10n.format(
            "export.stranded.detail", Set(folders).sorted().joined(separator: "\n"))
        alert.present(for: terminalWindowControllers.first?.window) { _ in }
    }

    /// The first of `windows` showing a close confirmation as a sheet.
    static func windowAskingToClose(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.attachedSheet?.identifier == SplitViewController.closeConfirmationIdentifier }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        stallTimer?.invalidate()
        stallTimer = nil
        isTerminating = true
        // Every store's last write at once, under one deadline: one after
        // another, a slow disk could spend each its own second in turn.
        let writes = DispatchGroup()
        let deadline = DispatchTime.now() + Self.quitFlushDeadline
        pendingLayoutSave?.cancel()
        pendingLayoutSave = nil
        saveWindowStates(completion: writes)
        DirectoryHistoryStore.shared.flush(into: writes, deadline: deadline)
        RecentHostsStore.flushSharedAtQuit(into: writes, deadline: deadline)
        RemoteEditStore.flushSharedAtQuit(into: writes)
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
        // Not left to the panes' background removals: the process is ending.
        FileDropStorage.removeThisRun(into: writes, deadline: deadline)
        _ = writes.wait(timeout: deadline)
    }

    /// How long a quit waits for the last writes, all of them together.
    static let quitFlushDeadline: DispatchTimeInterval = .milliseconds(1500)

    /// AppKit restoration is off: a live process isn't a document.
    /// `SessionRestore` saves the arrangement instead.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Saving from a menu

extension AppDelegate {
    /// A menu has no status row to say a write failed, as Settings does, so it
    /// says so here: the tick would simply stay where it was, and a toast
    /// claiming the change happened would be worse. Returns whether it saved.
    @discardableResult
    func saveFromMenu(_ change: (inout Configuration) -> Void) -> Bool {
        Self.save(change, to: .shared) {
            NSApp.keyWindow?.terminalSplit?.focusedPane?.terminalView?.showToast(
                L10n.text("toast.settingNotSaved"), kind: .warning)
        }
    }

    static func save(
        _ change: (inout Configuration) -> Void, to store: ConfigurationStore, onFailure: () -> Void
    ) -> Bool {
        guard store.update(change) else {
            onFailure()
            return false
        }
        return true
    }
}
