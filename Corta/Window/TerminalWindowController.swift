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

/// The window controller behind every terminal window: it builds the window
/// with its final style mask, owns the window's tabs (D30) and the toolbar
/// whose strip shows them, and is the window's delegate —
/// `windowShouldClose` is where the "still running" confirmation lives.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    /// The mask every terminal window has from creation. Content runs under
    /// the titlebar; the grid's top inset follows the chrome
    /// (`TerminalPaneViewController.windowChrome`).
    static let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]

    /// The window's tabs, in strip order; never empty while the window is open.
    private(set) var tabs: [TerminalTab] = []
    private(set) weak var selectedTab: TerminalTab?
    let container = TabContainerViewController()
    let tabStrip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
    /// The toolbar's input-source slot; the selected tab's focused pane
    /// places its badge here (`SplitViewController.placeInputSourceIndicator`).
    let inputSourceToolbarHost = NSView(frame: CGRect(x: 0, y: 0, width: 28, height: 24))
    var inputSourceToolbarSpacer: NSToolbarItem?

    /// A window whose root pane spawns from `setup`, dressed and sized for
    /// its first grid before anything shows it. Unrestored windows are
    /// centred on the main screen; the caller cascades or places them after.
    convenience init(setup: SplitViewController.Setup) {
        self.init(window: Self.makeWindow())
        dressWindow()
        // Loads the split's view, which spawns the root pane from `setup`.
        let tab = makeTab(setup: setup, hidden: false)
        selectedTab = tab
        tab.split.prepareWindow(window!)
        refreshTabStrip()
    }

    /// A window for a tab that is already running, taken from another
    /// window (D30, between windows): its panes keep their sessions, and
    /// the window takes `frame` rather than a size from the grid.
    convenience init(adopting tab: TerminalTab, frame: NSRect) {
        let window = Self.makeWindow()
        self.init(window: window)
        dressWindow()
        // `prepareWindow` does this for a window born with its tab.
        applyCanvasAppearance()
        window.setFrame(frame, display: false)
        adopt(tab)
        container.add(tab.split, hidden: false)
        tab.split.rejoinWindow(window)
        selectedTab = tab
        refreshTabStrip()
    }

    private static func makeWindow() -> NSWindow {
        let placeholder = NSRect(x: 0, y: 0, width: 480, height: 270)
        let window = NSWindow(
            contentRect: placeholder, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Corta draws its own tabs (D30); AppKit's would add a second bar.
        window.tabbingMode = .disallowed
        // A live process, not a document; every window, however it was born.
        // Left restorable, AppKit re-applied a stale saved frame after sizing.
        window.isRestorable = false
        // Link and tab tooltips only while Corta is active, as the storyboard
        // window had it.
        window.allowsToolTipsWhenApplicationIsInactive = false
        return window
    }

    private func dressWindow() {
        guard let window else { return }
        window.delegate = self
        tabStrip.delegate = self
        installToolbar(on: window)
        installSecureInputIndicator()
        window.contentViewController = container
    }

    /// The App Intent identity of the selected tab (`TerminalWindowEntity`).
    var windowID: String {
        get { selectedTab?.id ?? "" }
        set { selectedTab?.id = newValue }
    }

    private var splitController: SplitViewController? { selectedTab?.split }

    /// A titlebar lock while Secure Keyboard Entry is engaged — the effect is
    /// invisible otherwise. Follows `SecureInput.engaged`, not the setting.
    private(set) var secureInputIndicator: NSTitlebarAccessoryViewController?
    private var secureInputObserver: NSObjectProtocol?
    /// What the lock reads, injectable so a test never engages the machine's
    /// secure input or needs a real key window.
    var secureInputIsEngaged: () -> Bool = { SecureInput.shared.engaged }
    lazy var windowIsKey: () -> Bool = { [weak self] in self?.window?.isKeyWindow ?? false }
    private var isStripRefreshPending = false

    isolated deinit {
        if let secureInputObserver { NotificationCenter.default.removeObserver(secureInputObserver) }
    }

}

// MARK: - Tabs

extension TerminalWindowController {

    private func makeTab(setup: SplitViewController.Setup, hidden: Bool) -> TerminalTab {
        let split = SplitViewController(setup: setup)
        let tab = TerminalTab(split: split)
        adopt(tab)
        if let restore = setup.restore {
            if let id = restore.id { tab.id = id }
            tab.customTitle = restore.customTabTitle
        }
        container.add(split, hidden: hidden)
        // The window's temporary zoom (⌘+, pinch) is the window's, so a new
        // tab opens at it, as a new split does.
        if let zoomed = tabs.first(where: { $0 !== tab })?.split.focusedPane, zoomed.isFontSizeZoomed {
            split.setFontSizeForOwnPanes(zoomed.fontSize, isZoomed: true, settle: true)
        }
        return tab
    }

    /// ⌘= / ⌘− / ⌘0 and pinch, for every tab: a temporary zoom is per
    /// window, not per tab.
    func setFontSizeForAllTabs(_ size: CGFloat, isZoomed: Bool, settle: Bool) {
        for tab in tabs { tab.split.setFontSizeForOwnPanes(size, isZoomed: isZoomed, settle: settle) }
    }

    func settleFontChangeForAllTabs() {
        for tab in tabs { tab.split.settleFontChangeForOwnPanes() }
    }

    /// Takes `tab` into the window's list, selected if it is the first; its
    /// view is the caller's to place.
    func adopt(_ tab: TerminalTab) {
        tab.controller = self
        tabs.append(tab)
        if selectedTab == nil { selectedTab = tab }
    }

    /// A new tab after the last, its root pane spawned from `setup`. A
    /// restored background tab passes `select: false`.
    @discardableResult
    func addTab(setup: SplitViewController.Setup = .init(), select: Bool = true) -> TerminalTab {
        let tab = makeTab(setup: setup, hidden: true)
        if let window { tab.split.joinWindow(window) }
        if select {
            // The tab in front stays drawn until the new shell's first output
            // is on the canvas, so the switch never shows an empty one.
            let previous = window?.isVisible == true ? selectedTab?.split : nil
            if let previous, let pane = tab.split.focusedPane, !pane.drewFirstOutput {
                pane.onFirstOutputFrame = { [weak container, weak previous] in
                    // The frame being prepared presents within a vsync or so.
                    DispatchQueue.main.asyncAfter(deadline: .now() + TabContainerViewController.firstFrameDelay) {
                        // Only the hold it was for: a second ⌘T holds another.
                        container?.releaseHeld(ifHolding: previous)
                    }
                }
                selectTab(tab, holding: previous)
            } else {
                selectTab(tab)
            }
        } else {
            refreshTabStrip()
        }
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
        return tab
    }

    func selectTab(_ tab: TerminalTab, holding previous: SplitViewController? = nil) {
        guard let window, tabs.contains(where: { $0 === tab }) else { return }
        let changed = selectedTab !== tab
        let leaving = selectedTab
        // Back toward the start of the row, the canvas moves the other way.
        let from = tabs.firstIndex { $0 === leaving }, to = tabs.firstIndex { $0 === tab }
        let backward = from.flatMap { from in to.map { $0 < from } } ?? false
        selectedTab = tab
        container.show(tab.split, holding: previous, direction: backward ? -1 : 1)
        tab.split.didBecomeSelectedTab()
        // Choosing the tab already shown leaves the keyboard where it is in
        // it — a search field, a rename — rather than taking it back to the
        // terminal.
        let responderInTab = (window.firstResponder as? NSView)?.isDescendant(of: tab.split.view) == true
        if changed || ((window.isKeyWindow || !window.isVisible) && !responderInTab) {
            window.makeFirstResponder(tab.split.focusedPane?.terminalView)
        }
        tab.split.applyWindowTitle()
        refreshTabStrip()
        if changed {
            // Focus reports (?1004) for the tab left and the tab shown: a
            // program in a hidden tab is not focused, whatever its split says.
            for pane in (leaving?.split.panes ?? []) + tab.split.panes { pane.focus.reportIfNeeded() }
            (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
        }
    }

    func selectAdjacentTab(offset: Int) {
        guard tabs.count > 1, let current = selectedTab,
              let index = tabs.firstIndex(where: { $0 === current }) else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// ⌘1–⌘8 select that tab; ⌘9 the last, as browsers do.
    func selectTab(number: Int) {
        guard !tabs.isEmpty, number >= 1 else { return }
        // A tab past the last is not there: nothing, as in a browser.
        if number >= 9 {
            selectTab(tabs[tabs.count - 1])
        } else if number <= tabs.count {
            selectTab(tabs[number - 1])
        }
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination
        else { return }
        tabs.insert(tabs.remove(at: source), at: destination)
        refreshTabStrip()
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
    }

    /// Closes `tab`, asking first when something runs in it; the last tab is
    /// the window's own close, which asks in `windowShouldClose`.
    func performCloseTab(_ tab: TerminalTab, sender: Any? = nil) {
        guard let window else { return }
        guard tabs.count > 1 else {
            window.performClose(sender)
            return
        }
        let running = tab.split.panesWithRunningJobs
        guard tab.split.needsCloseConfirmation(for: running) else {
            closeTab(tab)
            return
        }
        // One question at a time: a sheet already up is still asking.
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        if selectedTab !== tab { selectTab(tab) }
        let scope = L10n.text("close.scope.tab")
        tab.split.confirmClose(of: running, scope: scope, in: window) { [weak self, weak tab] confirmed in
            guard confirmed, let self, let tab else { return }
            self.closeTab(tab)
        }
    }

    /// Takes `tab` out of this window with its panes still running, for
    /// another window to receive. Never the last tab: that is the window.
    @discardableResult
    func release(_ tab: TerminalTab) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        tabs.remove(at: index)
        container.remove(tab.split)
        if selectedTab === tab {
            selectTab(tabs[min(index, tabs.count - 1)])
        } else {
            refreshTabStrip()
        }
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
        return true
    }

    /// Every tab, still running, out of this window, which is left empty
    /// for the caller to close: a closing window tears down only the tabs
    /// it still holds (`AppDelegate.windowWillClose`).
    func releaseAllTabs() -> [TerminalTab] {
        let released = tabs
        for tab in released { container.remove(tab.split) }
        tabs.removeAll()
        selectedTab = nil
        return released
    }

    /// A running tab from another window, at `index` (after the last by
    /// default), brought to the front.
    func receive(_ tab: TerminalTab, at index: Int? = nil) {
        guard let window, !tabs.contains(where: { $0 === tab }) else { return }
        tab.controller = self
        tabs.insert(tab, at: min(max(0, index ?? tabs.count), tabs.count))
        container.add(tab.split, hidden: true)
        tab.split.rejoinWindow(window)
        selectTab(tab)
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
    }

    /// Closes `tab` without asking; the last tab closes the window.
    func closeTab(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else {
            window?.close()
            return
        }
        tab.split.teardown()
        tabs.remove(at: index)
        if selectedTab === tab {
            container.retire(tab.split)
        } else {
            container.remove(tab.split)
        }
        if selectedTab === tab || selectedTab == nil {
            selectTab(tabs[min(index, tabs.count - 1)])
        } else {
            refreshTabStrip()
        }
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
    }

    /// Closes every tab but `keep`, asking once for all of them: one sheet
    /// per tab would leave all but the first unasked and open.
    func closeOtherTabs(than keep: TerminalTab) {
        guard let window, tabs.contains(where: { $0 === keep }) else { return }
        let others = tabs.filter { $0 !== keep }
        guard !others.isEmpty else { return }
        let running = others.flatMap { $0.split.panesWithRunningJobs }
        let closeAll: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // Re-read: a tab may have closed itself while the sheet was up.
            for tab in self.tabs where tab !== keep && others.contains(where: { $0 === tab }) {
                self.closeTab(tab)
            }
        }
        guard keep.split.needsCloseConfirmation(for: running) else {
            closeAll()
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        if selectedTab !== keep { selectTab(keep) }
        keep.split.confirmClose(of: running, scope: L10n.text("close.scope.otherTabs"), in: window) { confirmed in
            if confirmed { closeAll() }
        }
    }

    /// Redraws the strip from every tab's focused program and title, and the
    /// window title from the selected tab.
    /// Output from any pane asks for this, many times a second while a
    /// program streams: the strip's views are touched only when an item or
    /// the selection changed, or `force` says the colours did.
    func refreshTabStrip(force: Bool = false) {
        let items = tabs.map(TabIcon.item(for:))
        let selected = tabs.firstIndex { $0 === selectedTab } ?? 0
        guard force || items != tabStrip.items || selected != tabStrip.selectedIndex else { return }
        tabStrip.update(items: items, selectedIndex: selected)
    }

    /// For output, which asks once a frame while a program streams: building
    /// an item per tab that often is work nobody can see. A tenth of a second
    /// is well inside what reads as the moment the program changed.
    func refreshTabStripSoon() {
        guard !isStripRefreshPending else { return }
        isStripRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stripRefreshInterval) { [weak self] in
            self?.isStripRefreshPending = false
            self?.refreshTabStrip()
        }
    }

    static let stripRefreshInterval: TimeInterval = 0.1

    /// Kept for the panes and splits that report a title change.
    func refreshTabTitle() { refreshTabStrip() }

    func beginTabRename() {
        guard let selectedTab, let index = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        window?.makeKeyAndOrderFront(nil)
        tabStrip.beginRename(at: index)
    }

    func applyCanvasAppearance() {
        guard let window else { return }
        window.isOpaque = true
        // The band shares the gaps' ground colour; the cards sit on it.
        window.backgroundColor = PaneSurfaceView.gutterColor
        // The titlebar band is the theme's own colour, not a material: the
        // window's background shows through it, and the grid's top inset
        // keeps output below it (D24, amended). The tabs and pane headers
        // already name what runs, so the title text is not repeated above
        // them; it stays the window's title for the Window menu and
        // accessibility.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // The theme moved: same items, new colours.
        refreshTabStrip(force: true)
    }

    private func installSecureInputIndicator() {
        guard let window, secureInputObserver == nil else { return }
        let image = NSButton(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            ?? NSImage(), target: self, action: #selector(showSecureInputSettings(_:)))
        image.isBordered = false
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = L10n.text("secureInput.indicator.tooltip")
        image.setAccessibilityLabel(L10n.text("secureInput.indicator.tooltip"))
        image.translatesAutoresizingMaskIntoConstraints = false
        // Sized by frame: AppKit's own accessory constraints conflicted with
        // width/height constraints on every window.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
        container.addSubview(image)
        NSLayoutConstraint.activate([
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        secureInputIndicator = accessory
        secureInputObserver = NotificationCenter.default.addObserver(
            forName: SecureInput.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSecureInputIndicator() }
        }
        updateSecureInputIndicator()
    }

    @objc private func showSecureInputSettings(_ sender: Any?) {
        SettingsWindowController.shared.showPrivacySettings(sender)
    }

    func updateSecureInputIndicator() {
        guard window != nil else { return }
        let hidden = !(secureInputIsEngaged() && windowIsKey())
        secureInputIndicator?.isHidden = hidden
        // Native tab/titlebar transitions can retain an accessory's layout;
        // hide its view too so an inactive lock cannot remain visible.
        secureInputIndicator?.view.isHidden = hidden
    }

    /// Experimental (`DirectFullScreen.toolbar`): the chrome auto-hides in
    /// full screen with one pane. Not shipped — a visible toolbar does not
    /// stop direct presentation.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        let active = DirectFullScreen.requested.active(
            isFullScreen: true, paneCount: splitController?.panes.count ?? 0)
        guard active.contains(.toolbar) else { return proposedOptions }
        return proposedOptions.union([.fullScreen, .autoHideToolbar, .autoHideMenuBar])
    }

    /// The lock shows on the key window only. Moving between two terminal
    /// windows leaves secure input engaged, so `SecureInput.didChange` never
    /// posts and the window losing key kept its lock; each window follows
    /// its own key state too.
    func windowDidBecomeKey(_ notification: Notification) {
        updateSecureInputIndicator()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateSecureInputIndicator()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        beginFullScreenTransition()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        beginFullScreenTransition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        endFullScreenTransition()
        splitController?.updateDirectPresentation()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        endFullScreenTransition()
        splitController?.updateDirectPresentation()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        endFullScreenTransition()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        endFullScreenTransition()
    }

    /// The chrome changes through a full-screen transition, not with a tab
    /// bar: none of it is owed to the window's height. Every tab, since the
    /// one shown may change before it ends.
    private func beginFullScreenTransition() {
        for tab in tabs { tab.split.isChangingFullScreen = true }
    }

    private func endFullScreenTransition() {
        for tab in tabs {
            tab.split.isChangingFullScreen = false
            tab.split.resetChromeBaseline()
        }
    }

    /// Asks as a sheet, so the answer comes after this returns: refuse now,
    /// and close once confirmed. `close()` does not ask again. Every tab's
    /// running jobs count: the window takes them all.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let splitController else { return true }
        let running = tabs.flatMap { $0.split.panesWithRunningJobs }
        guard splitController.needsCloseConfirmation(for: running) else { return true }
        // A second ⌘W while the sheet is up: the sheet already asks.
        if sender.attachedSheet != nil, sender.isVisible { return false }
        // A minimised window has nowhere to show a sheet: ask now and answer
        // now, rather than close it from inside this call.
        guard NSAlert.canPresentSheet(on: sender) else {
            let alert = splitController.closeAlert(for: running, scope: L10n.text("close.scope.window"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        splitController.confirmClose(
            of: running, scope: L10n.text("close.scope.window"), in: sender
        ) { [weak sender] confirmed in if confirmed { sender?.close() } }
        return false
    }
}

extension TerminalWindowController {
    /// Read at quit and on every window close: one state per tab, grouped
    /// by a window identity when there is more than one.
    var restorableStates: [WindowState] {
        guard let window else { return [] }
        let group = tabs.count > 1 ? (tabs.first?.id ?? UUID().uuidString) : nil
        return tabs.enumerated().compactMap { index, tab in
            var state = tab.split.windowState(frame: window.frame)
            state?.id = tab.id
            state?.customTabTitle = tab.customTitle
            state?.tabGroupID = group
            state?.tabIndex = group == nil ? nil : index
            state?.isSelectedTab = tab === selectedTab
            return state
        }
    }
}

extension TerminalWindowController: TabStripDelegate {
    func tabStrip(_: TabStripView, select index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    func tabStrip(_: TabStripView, close index: Int) {
        guard tabs.indices.contains(index) else { return }
        performCloseTab(tabs[index])
    }

    func tabStrip(_: TabStripView, closeOthersThan index: Int) {
        guard tabs.indices.contains(index) else { return }
        closeOtherTabs(than: tabs[index])
    }

    func tabStrip(_: TabStripView, move from: Int, to: Int) {
        moveTab(from: from, to: to)
    }

    func tabStrip(_: TabStripView, rename id: String, to title: String?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.customTitle = title
        tab.split.applyWindowTitle()
        refreshTabStrip()
    }

    func tabStripNewTab(_: TabStripView) {
        (NSApp.delegate as? AppDelegate)?.newTab(beside: window, sender: nil)
    }

    func tabStrip(_: TabStripView, drop index: Int, atScreenPoint point: NSPoint) {
        guard tabs.indices.contains(index) else { return }
        drop(tabs[index], atScreenPoint: point)
    }

    func tabStrip(_: TabStripView, moveToNewWindow index: Int) {
        guard tabs.indices.contains(index) else { return }
        moveToNewWindow(tabs[index])
    }
}
