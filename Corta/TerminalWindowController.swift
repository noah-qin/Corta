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

/// The window controller behind every terminal window, chiefly for
/// `windowShouldClose`: the red button and ⌘W end at the window's delegate,
/// and this is where the "still running" confirmation lives.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private var splitController: SplitViewController? {
        contentViewController as? SplitViewController
    }

    /// The App Intent identity (`TerminalWindowEntity`), carried through
    /// `WindowState` so it survives a relaunch. Never the title, which the
    /// child writes.
    var windowID: String = UUID().uuidString

    /// The Quick Terminal's window: not saved or listed as an ordinary one.
    var isQuickTerminal = false

    /// User-owned title; terminal output must never overwrite it.
    var customTabTitle: String?
    private var tabTitleField: TabTitleField?
    private var tabEventMonitor: Any?

    func refreshTabTitle() {
        guard let window else { return }
        if tabTitleField == nil {
            let field = TabTitleField(controller: self)
            tabTitleField = field
        }
        if tabTitleField?.isEditingTitle != true { window.tab.title = window.title }
        window.tab.toolTip = window.title + "\n" + L10n.text("tab.rename.gesture")
        tabTitleField?.refresh(title: window.title)
    }

    /// Find the selected native tab through its public accessibility frame.
    fileprivate func selectedTabFrame(in host: NSView) -> NSRect? {
        guard let window else { return nil }
        func find(_ element: NSAccessibilityProtocol, depth: Int) -> NSRect? {
            guard depth < 12 else { return nil }
            if element.accessibilitySubrole()?.rawValue == "AXTabButton",
               element.accessibilityValue() as? Bool == true {
                return host.convert(window.convertFromScreen(element.accessibilityFrame()), from: nil)
            }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? NSAccessibilityProtocol,
                   let frame = find(child, depth: depth + 1) { return frame }
            }
            return nil
        }
        return find(window, depth: 0)
    }

    func beginTabRename() {
        guard let window else { return }
        if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        refreshTabTitle()
        // Native tab selection finishes its responder/layout changes after
        // this action returns. Begin editing once that transition has settled.
        DispatchQueue.main.async { [weak self] in self?.tabTitleField?.beginEditing() }
    }

    func applyCanvasAppearance() {
        guard let window else { return }
        let color = TerminalColorPalette.defaultBackground
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y),
                                         blue: CGFloat(color.z), alpha: 1)
        window.titlebarAppearsTransparent = false
    }

    /// A titlebar lock while Secure Keyboard Entry is engaged — the effect is
    /// invisible otherwise. Follows `SecureInput.engaged`, not the setting.
    private var secureInputIndicator: NSTitlebarAccessoryViewController?
    private var secureInputObserver: NSObjectProtocol?

    isolated deinit {
        if let secureInputObserver { NotificationCenter.default.removeObserver(secureInputObserver) }
        if let tabEventMonitor { NSEvent.removeMonitor(tabEventMonitor) }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        installSecureInputIndicator()
        installTabInteractions()
    }

    /// A local monitor sees clicks before AppKit's native tab cell starts its
    /// tracking loop. Public accessibility frames identify the tab; no private
    /// classes, selectors or replacement tab bar are required.
    private func installTabInteractions() {
        guard tabEventMonitor == nil else { return }
        tabEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let eventWindow = event.window, eventWindow === self.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control) || event.clickCount == 2
            else { return event }
            let point = eventWindow.convertPoint(toScreen: event.locationInWindow)
            guard let target = self.tabController(at: point, in: eventWindow),
                  target.tabTitleField?.isEditingTitle != true else { return event }
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                let nativeMenu = self.nativeTabMenu(for: event, in: eventWindow)
                target.window?.tabGroup?.selectedWindow = target.window
                target.window?.makeKeyAndOrderFront(nil)
                target.refreshTabTitle()
                if let menu = target.tabTitleField?.makeTabMenu(base: nativeMenu), let content = eventWindow.contentView {
                    NSMenu.popUpContextMenu(menu, with: event, for: content)
                }
            } else {
                target.beginTabRename()
            }
            return nil
        }
    }

    private func nativeTabMenu(for event: NSEvent, in window: NSWindow) -> NSMenu? {
        guard let frameView = window.contentView?.superview else { return nil }
        var view = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        while let candidate = view {
            if let menu = candidate.menu(for: event), !menu.items.isEmpty {
                let copy = menu.copy() as? NSMenu
                copy?.delegate = nil
                return copy
            }
            view = candidate.superview
        }
        return nil
    }

    private func tabController(at point: NSPoint, in eventWindow: NSWindow) -> TerminalWindowController? {
        var element = eventWindow.accessibilityHitTest(point) as? NSAccessibilityProtocol
        for _ in 0..<12 {
            guard let current = element else { return nil }
            if current.accessibilitySubrole()?.rawValue == "AXTabButton",
               let parent = current.accessibilityParent() as? NSAccessibilityProtocol {
                let tabs = (parent.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
                    .filter { $0.accessibilitySubrole()?.rawValue == "AXTabButton" }
                guard let index = tabs.firstIndex(where: { NSPointInRect(point, $0.accessibilityFrame()) }),
                      let windows = eventWindow.tabGroup?.windows, index < windows.count else { return nil }
                // Let native close buttons retain their own double-click behaviour.
                if let children = current.accessibilityChildren(), children.contains(where: {
                    guard let child = $0 as? NSAccessibilityProtocol else { return false }
                    return child.accessibilityRole()?.rawValue == "AXButton" && NSPointInRect(point, child.accessibilityFrame())
                }) { return nil }
                return windows[index].windowController as? TerminalWindowController
            }
            element = current.accessibilityParent() as? NSAccessibilityProtocol
        }
        return nil
    }

    /// Swaps the storyboard's `NSWindow` for a non-activating `NSPanel` with
    /// the same content, before it is shown.
    ///
    /// An inactive app's window never reaches a full-screen Space, whatever
    /// its collection behaviour, and `NSApp.activate()` is refused or drags
    /// the user out of the Space. Measured on macOS 27 over full-screen
    /// TextEdit: `kCGWindowIsOnscreen` stayed false for every `NSWindow`
    /// variant and became true for a `.nonactivatingPanel`.
    ///
    /// Done here because this controller knows what `windowDidLoad` put on the
    /// old window (the lock); `viewWillAppear` then runs against the panel as
    /// usual.
    func adoptNonactivatingPanel() {
        guard let old = window, !(old is NSPanel) else { return }
        let panel = NSPanel(
            contentRect: old.contentRect(forFrameRect: old.frame),
            styleMask: old.styleMask.union(.nonactivatingPanel),
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // `QuickTerminalController` owns dismissal and focus return.
        panel.hidesOnDeactivate = false
        panel.title = old.title
        let content = old.contentViewController
        old.delegate = nil
        old.contentViewController = nil
        panel.contentViewController = content
        panel.delegate = self
        window = panel
        installSecureInputIndicator()
    }

    private func installSecureInputIndicator() {
        guard let window else { return }
        // Once per window owned: drop the previous window's observer.
        if let secureInputObserver { NotificationCenter.default.removeObserver(secureInputObserver) }
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

    private func updateSecureInputIndicator() {
        guard let window else { return }
        let hidden = !(SecureInput.shared.engaged && window.isKeyWindow)
        secureInputIndicator?.isHidden = hidden
        // Native tab/titlebar transitions can retain an accessory's layout;
        // hide its view too so an inactive lock cannot remain visible.
        secureInputIndicator?.view.isHidden = hidden
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let splitController else { return true }
        let running = splitController.panesWithRunningJobs
        return splitController.confirmClose(of: running, scope: L10n.text("close.scope.window"))
    }

    /// Read at quit and on every window close.
    var restorableState: WindowState? {
        guard let window, let splitController, !isQuickTerminal else { return nil }
        var state = splitController.windowState(frame: window.frame)
        state?.id = windowID
        state?.customTabTitle = customTabTitle
        return state
    }
}


/// Owns only the native tab's title. AppKit still owns the tab bar, its close
/// buttons, drag/reorder behaviour and grouping. No private view classes.
private final class TabTitleField: NSTextField, NSTextFieldDelegate {
    private weak var controller: TerminalWindowController?
    private var editingTitle = false
    var isEditingTitle: Bool { editingTitle }
    private var startingEditor = false

    override var acceptsFirstResponder: Bool { editingTitle }
    private var originalTitle = ""

    init(controller: TerminalWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        delegate = self
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lineBreakMode = .byTruncatingTail
        alignment = .center
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityIdentifier("tab-title")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let count = max(1, controller?.window?.tabGroup?.windows.count ?? 1)
        let width = ((controller?.window?.frame.width ?? 400) - 40) / CGFloat(count) - 32
        return NSSize(width: editingTitle ? max(80, width) : 0, height: 22)
    }

    func refresh(title: String) {
        guard !editingTitle else { return }
        stringValue = title
        toolTip = L10n.text("tab.rename.gesture")
        setAccessibilityLabel(title)
        invalidateIntrinsicContentSize()
    }

    func beginEditing() {
        guard !editingTitle else { return }
        startingEditor = true
        defer { startingEditor = false }
        guard let window = controller?.window, let host = window.contentView?.superview,
              let tabFrame = controller?.selectedTabFrame(in: host) else { return }
        originalTitle = stringValue
        editingTitle = true
        // Overlay the native title at its center; an accessory is trailing-aligned.
        let width = max(40, min(tabFrame.width - 32, max(120, tabFrame.width * 0.8)))
        let height = cell?.cellSize.height ?? 16
        frame = NSRect(x: tabFrame.midX - width / 2, y: tabFrame.midY - height / 2,
                       width: width, height: height)
        host.addSubview(self, positioned: .above, relativeTo: nil)
        window.tab.title = ""
        isHidden = false
        setAccessibilityIdentifier("tab-title-editor")
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        invalidateIntrinsicContentSize()
        selectText(nil)
    }

    private func finishEditing(save: Bool) {
        guard editingTitle else { return }
        let value = stringValue
        editingTitle = false
        window?.makeFirstResponder(nil)
        removeFromSuperview()
        setAccessibilityIdentifier("tab-title")
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        if save, let split = controller?.contentViewController as? SplitViewController {
            split.setCustomTabTitle(value)
        } else {
            refresh(title: originalTitle)
        }
        controller?.refreshTabTitle()
        if let split = controller?.contentViewController as? SplitViewController {
            controller?.window?.makeFirstResponder(split.focusedPane?.terminalView)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        editingTitle ? super.menu(for: event) : makeTabMenu()
    }

    func makeTabMenu(base: NSMenu? = nil) -> NSMenu {
        let menu = base ?? NSMenu()
        if base == nil {
            let close = NSMenuItem(title: TerminalCommand.close.title,
                action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
            close.target = controller?.window
            menu.addItem(close)
        }
        menu.insertItem(.separator(), at: 0)
        let newTab = NSMenuItem(title: TerminalCommand.newTab.title,
            action: TerminalCommand.newTab.action, keyEquivalent: "")
        newTab.target = NSApp.delegate
        let shortcut = ConfigurationStore.shared.configuration.keybindings[.newTab]
        newTab.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        newTab.keyEquivalentModifierMask = shortcut?.menuModifierMask ?? []
        if let existing = menu.items.first(where: { $0.title == newTab.title }) { menu.removeItem(existing) }
        menu.insertItem(newTab, at: 0)
        let rename = NSMenuItem(title: TerminalCommand.renameTab.title,
            action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        menu.insertItem(rename, at: 1)
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        if editingTitle { super.rightMouseDown(with: event); return }
        guard let target = controller?.window else { return }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    @objc private func renameFromMenu(_ sender: Any?) { controller?.beginTabRename() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !startingEditor else { return }
        finishEditing(save: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(save: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(save: true)
            return true
        }
        return false
    }
}
