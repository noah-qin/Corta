import AppKit

/// B16 — the Quick Terminal: one terminal window summoned and dismissed by
/// a system-wide hotkey, from whatever application the user is in.
///
/// **It is an ordinary window, dressed differently.** The panel is the
/// storyboard's `TerminalWindowController` — the same `SplitViewController`,
/// panes, sizing gate and teardown as ⌘N — configured after it exists: no
/// visible titlebar, floating above other windows, present on every Space
/// and beside full-screen applications, and excluded from tabbing, the
/// Window menu and the saved arrangement. A second window class would be a
/// second copy of every rule in `SplitViewController.viewWillAppear`, and
/// D.1's sizing gate is the kind of rule that is wrong twice as easily.
///
/// **Focus goes back where it came from.** The application that was
/// frontmost when the hotkey was pressed is remembered and re-activated
/// when the panel is dismissed by the hotkey, so summoning a terminal over
/// an editor and dismissing it lands back in the editor — not in Corta's
/// nearest other window, and not in whatever the window server picks. A
/// panel that loses the app's activation some other way (the user clicked
/// into another app) hides without touching activation: they already went
/// where they meant to.
///
/// **The hotkey is the only thing the setting gates.** `quick-terminal =
/// false` (the default) means no key is claimed system-wide; the panel is
/// still reachable from View ▸ Quick Terminal, the palette and the App
/// Intent, because none of those take anything from the rest of the
/// desktop.
@MainActor
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    private var controller: TerminalWindowController?
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggle() }
    private var observers: [NSObjectProtocol] = []
    /// The application to return to on dismissal, captured at summon time.
    private var previousApplication: NSRunningApplication?

    /// Whether the last attempt to claim the configured hotkey was refused
    /// by the system — another process holds it. Surfaced in Settings,
    /// since the alternative is a key that silently does nothing.
    private(set) var hotKeyRegistrationFailed = false
    static let hotKeyStatusDidChange = Notification.Name("QuickTerminalController.hotKeyStatusDidChange")

    /// The fraction of the screen's visible height a top or bottom band
    /// takes, and the fraction of both axes the centred panel takes.
    nonisolated static let bandHeightFraction: CGFloat = 0.4
    nonisolated static let centeredFraction = CGSize(width: 0.7, height: 0.6)
    nonisolated private static let slideDistance: CGFloat = 24
    private static let animationDuration: TimeInterval = 0.16

    func start() {
        let center = NotificationCenter.default
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
        ]
        applyConfiguration()
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

    /// Whether `window` is the Quick Terminal's.
    func owns(_ window: NSWindow?) -> Bool {
        guard let window, let panel = controller?.window else { return false }
        return window === panel
    }

    var isVisible: Bool { controller?.window?.isVisible == true }

    /// The hotkey, the menu item and the App Intent all land here.
    func toggle() {
        if let window = controller?.window, window.isVisible {
            if window.isKeyWindow || !NSApp.isActive {
                hide(returningFocus: true)
            } else {
                // Visible but behind another Corta window: the hotkey means
                // "bring it to me", not "put it away".
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
        NSApp.activate()
        let offset = Self.slideOffset(for: configuration.quickTerminalPosition)
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: frame.minX + offset.width, y: frame.minY + offset.height))
        window.makeKeyAndOrderFront(nil)
        animate {
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Dismisses the panel. `returningFocus` re-activates the application
    /// the hotkey was pressed in; it is false when Corta already lost
    /// activation on its own.
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

    /// At quit: the window is torn down with the others by `AppDelegate`
    /// (it is tracked like any window); this only drops the hotkey so no
    /// callback fires into a process that is going away.
    func teardown() {
        hotKey.unregister()
    }

    // MARK: - The window

    private func makeWindow(frame: NSRect) -> TerminalWindowController? {
        // Born at its frame, through the same path a restored window takes:
        // `viewWillAppear` then applies this frame instead of sizing the
        // window from `columns × rows`, and the session is first told a
        // winsize it will actually keep (D.1).
        let state = WindowState(
            frame: WindowState.Frame(frame), layout: .pane(directory: nil, isFocused: true))
        guard let delegate = NSApp.delegate as? AppDelegate,
            let controller = delegate.instantiateWindowController(
                setup: SplitViewController.Setup(restore: state)) as? TerminalWindowController,
            let window = controller.window
        else { return nil }
        controller.isQuickTerminal = true
        controller.showWindow(nil)
        // After `viewWillAppear`, which sets `.automatic` for ordinary
        // windows: the panel takes no tabs, and ⌘T from it opens a normal
        // window (`AppDelegate.newTab`).
        window.tabbingMode = .disallowed
        window.level = .floating
        // Every Space, and beside a full-screen application rather than
        // switching the user out of it. `.transient` keeps Mission Control
        // from treating the band as a window to arrange.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isExcludedFromWindowsMenu = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // The band is placed by the screen's geometry, not by the user, so
        // there is nothing to drag it by — and a panel that could be moved
        // would open in the wrong place the next time.
        window.isMovable = false
        window.animationBehavior = .none
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller = nil }
        }
        return controller
    }

    private func animate(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration =
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }

    // MARK: - Geometry

    /// The screen a summon lands on, by the configured rule.
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

    /// Where the panel sits inside a screen's *visible* frame — under the
    /// menu bar and clear of the Dock, whichever edge the Dock is on.
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

    /// The direction the panel comes in from: a band slides from its edge, a
    /// centred panel rises a little.
    nonisolated static func slideOffset(for position: Configuration.QuickTerminalPosition) -> NSSize {
        switch position {
        case .top: return NSSize(width: 0, height: slideDistance)
        case .bottom: return NSSize(width: 0, height: -slideDistance)
        case .center: return NSSize(width: 0, height: -slideDistance / 2)
        }
    }
}
