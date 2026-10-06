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

import AppKit

/// The Quick Terminal: one window summoned and dismissed by a system-wide
/// hotkey.
///
/// **An ordinary window, dressed differently.** It is a
/// `TerminalWindowController` — same panes, sizing and teardown as ⌘N —
/// configured afterwards: no titlebar, floating, on every Space, and outside
/// tabbing, the Window menu and the saved arrangement. A second window class
/// would duplicate `prepareWindow`'s rules. Only the window object differs:
/// a non-activating `NSPanel`, since an inactive app's window never reaches
/// a full-screen Space (`TerminalWindowController.init(setup:asPanel:)`).
///
/// **Focus goes back where it came from.** Dismissing by hotkey
/// re-activates the app that was frontmost at summon; losing activation
/// otherwise just hides.
///
/// **The setting gates only the hotkey.** The menu, palette and App Intent
/// work regardless; none claims a key system-wide.
@MainActor
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    private var controller: TerminalWindowController?
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggle() }
    private var observers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
        if let windowObserver { notificationCenter.removeObserver(windowObserver) }
    }

    var observerCount: Int { observers.count + (windowObserver == nil ? 0 : 1) }
    /// A slide is in flight. Display changes wait for it: `show()` animates to
    /// a frame captured before the change, and `hide()` undoes a fixed
    /// offset, so a reposition mid-slide would be overwritten.
    private var isAnimating = false
    private var repositionWhenIdle = false

    /// The app to return to on dismissal.
    private var previousApplication: NSRunningApplication?

    /// Another process holds the hotkey; shown in Settings rather than let
    /// the key silently do nothing.
    private(set) var hotKeyRegistrationFailed = false
    static let hotKeyStatusDidChange = Notification.Name("QuickTerminalController.hotKeyStatusDidChange")

    /// A band's share of visible height, and the centred panel's of both axes.
    nonisolated static let bandHeightFraction: CGFloat = 0.4
    nonisolated static let centeredFraction = CGSize(width: 0.7, height: 0.6)
    nonisolated private static let slideDistance: CGFloat = 24
    private static let animationDuration: TimeInterval = 0.16

    func start() {
        observeNotifications()
        applyConfiguration()
    }

    func observeNotifications() {
        guard observers.isEmpty else { return }
        let center = notificationCenter
        observers = [
            center.addObserver(forName: ConfigurationStore.didChange, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applyConfiguration() }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(returningFocus: false) }
            },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersDidChange() }
            },
        ]
    }

    private func applyConfiguration() {
        let configuration = ConfigurationStore.shared.configuration
        let wanted = configuration.quickTerminal ? configuration.quickTerminalKey : nil
        guard wanted != hotKey.shortcut || (wanted != nil && hotKeyRegistrationFailed) else {
            return
        }
        let registered = hotKey.register(wanted)
        let failed = wanted != nil && !registered
        if failed != hotKeyRegistrationFailed {
            hotKeyRegistrationFailed = failed
            NotificationCenter.default.post(name: Self.hotKeyStatusDidChange, object: self)
        }
    }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window, let panel = controller?.window else { return false }
        return window === panel
    }

    var isVisible: Bool { controller?.window?.isVisible == true }

    func toggle() {
        if let window = controller?.window, window.isVisible {
            if window.isKeyWindow || !NSApp.isActive {
                hide(returningFocus: true)
            } else {
                // Behind another Corta window, the hotkey means "bring it to me".
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            show()
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        let configuration = ConfigurationStore.shared.configuration
        let screen = Self.screen(for: configuration.quickTerminalScreen)
        let frame = Self.frame(
            for: configuration.quickTerminalPosition, in: screen?.visibleFrame ?? .zero)

        let controller: TerminalWindowController
        if let existing = self.controller {
            controller = existing
            controller.window?.setFrame(frame, display: false)
        } else {
            guard let created = makeWindow(frame: frame) else { return }
            controller = created
            self.controller = created
        }
        guard let window = controller.window else { return }
        let offset = Self.slideOffset(for: configuration.quickTerminalPosition)
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: frame.minX + offset.width, y: frame.minY + offset.height))
        // Order first, then activate: the non-activating panel is already key
        // on this Space, while activating first let the window server switch
        // Spaces out of a full-screen app.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        animate {
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Displays changed. A hidden panel needs nothing (`show()` recomputes);
    /// a visible one may sit on a gone screen, so it is moved, without
    /// animation.
    private func screenParametersDidChange() {
        guard !isAnimating else {
            repositionWhenIdle = true
            return
        }
        guard let window = controller?.window else { return }
        let configuration = ConfigurationStore.shared.configuration
        guard
            let frame = Self.frameAfterScreenChange(
                position: configuration.quickTerminalPosition,
                isVisible: window.isVisible,
                currentScreenVisibleFrame: window.screen?.visibleFrame,
                fallbackVisibleFrame: Self.screen(for: configuration.quickTerminalScreen)?
                    .visibleFrame)
        else { return }
        window.setFrame(frame, display: true)
    }

    /// `returningFocus` re-activates the summoning app; false when Corta
    /// already lost activation.
    func hide(returningFocus: Bool) {
        guard let window = controller?.window, window.isVisible else { return }
        let position = ConfigurationStore.shared.configuration.quickTerminalPosition
        let offset = Self.slideOffset(for: position)
        let target = window.frame.offsetBy(dx: offset.width, dy: offset.height)
        let previous = previousApplication
        previousApplication = nil
        animate {
            window.animator().alphaValue = 0
            window.animator().setFrame(target, display: true)
        } completion: {
            window.orderOut(nil)
            window.setFrame(window.frame.offsetBy(dx: -offset.width, dy: -offset.height), display: false)
            window.alphaValue = 1
        }
        if returningFocus, let previous, !previous.isTerminated {
            previous.activate()
        }
    }

    /// At quit: drops the hotkey; `AppDelegate` tears the window down.
    func teardown() {
        hotKey.unregister()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let windowObserver { notificationCenter.removeObserver(windowObserver) }
        windowObserver = nil
    }

    // MARK: - The window

    private func makeWindow(frame: NSRect) -> TerminalWindowController? {
        // Placed through the restore path: its frame is set before it shows.
        let state = WindowState(
            frame: WindowState.Frame(frame), layout: .pane(directory: nil, isFocused: true))
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        let controller = delegate.makeWindowController(
            setup: SplitViewController.Setup(restore: state), asPanel: true)
        guard let window = controller.window else { return nil }
        controller.isQuickTerminal = true
        controller.showWindow(nil)
        // After `prepareWindow` set `.automatic`: ⌘T from here opens a normal
        // window (`AppDelegate.newTab`).
        window.tabbingMode = .disallowed
        window.level = .floating
        // Every Space, beside full-screen apps; `.transient` keeps it out of
        // Mission Control.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isExcludedFromWindowsMenu = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Placed by screen geometry; a moved panel would reopen wrong.
        window.isMovable = false
        window.animationBehavior = .none
        observeClose(of: window)
        return controller
    }

    func observeClose(of window: NSWindow) {
        if let windowObserver { notificationCenter.removeObserver(windowObserver) }
        windowObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.windowObserver { self.notificationCenter.removeObserver(token) }
                self.windowObserver = nil
                self.controller = nil
            }
        }
    }

    private func animate(_ changes: @escaping () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                completion?()
                guard let self else { return }
                self.isAnimating = false
                // Apply a display change deferred during the slide.
                if self.repositionWhenIdle {
                    self.repositionWhenIdle = false
                    self.screenParametersDidChange()
                }
            }
        }
    }

    // MARK: - Geometry

    static func screen(for rule: Configuration.QuickTerminalScreen) -> NSScreen? {
        switch rule {
        case .main:
            return NSScreen.main ?? NSScreen.screens.first
        case .mouse:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// The panel's frame in a screen's visible frame, clear of menu bar and
    /// Dock.
    nonisolated static func frame(
        for position: Configuration.QuickTerminalPosition, in visible: NSRect
    ) -> NSRect {
        switch position {
        case .top:
            let height = (visible.height * bandHeightFraction).rounded(.down)
            return NSRect(
                x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
        case .bottom:
            let height = (visible.height * bandHeightFraction).rounded(.down)
            return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        case .center:
            let size = NSSize(
                width: (visible.width * centeredFraction.width).rounded(.down),
                height: (visible.height * centeredFraction.height).rounded(.down))
            return NSRect(
                x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: size.width, height: size.height)
        }
    }

    /// The frame after a display change, or nil. Pure because the event can't
    /// be produced in a test without changing the machine (D13).
    ///
    /// The panel keeps its current screen if it still exists; re-running the
    /// rule (`.mouse` especially) would move it. The window server relocates
    /// windows off an unplugged display before the notification, so the
    /// fallback is only for a panel left outside every screen.
    nonisolated static func frameAfterScreenChange(
        position: Configuration.QuickTerminalPosition,
        isVisible: Bool,
        currentScreenVisibleFrame: NSRect?,
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard isVisible else { return nil }
        guard let visible = currentScreenVisibleFrame ?? fallbackVisibleFrame else { return nil }
        return frame(for: position, in: visible)
    }

    /// A band slides from its edge; a centred panel rises a little.
    nonisolated static func slideOffset(for position: Configuration.QuickTerminalPosition) -> NSSize {
        switch position {
        case .top: return NSSize(width: 0, height: slideDistance)
        case .bottom: return NSSize(width: 0, height: -slideDistance)
        case .center: return NSSize(width: 0, height: -slideDistance / 2)
        }
    }
}
