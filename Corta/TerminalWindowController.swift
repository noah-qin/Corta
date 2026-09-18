import Cocoa

/// The window controller behind every terminal window.
///
/// It exists for one reason: `windowShouldClose`. The red button and ⌘W both
/// end at the window's delegate, and the delegate is the window controller —
/// so a "something is still running" confirmation (M7.5) has nowhere else to
/// live. Putting `SplitViewController` in the delegate slot instead would
/// take over every other delegate message `NSWindowController` answers, which
/// is a much larger change for the same one hook.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private var splitController: SplitViewController? {
        contentViewController as? SplitViewController
    }

    /// B16 — the identity an App Intent names this window by
    /// (`TerminalWindowEntity`). Minted when the controller is created and
    /// carried through `WindowState`, so a Shortcut that focuses "the build
    /// window" still resolves after a relaunch restores it. Never derived
    /// from the title: titles are written by the child process and change
    /// with every `cd`.
    var windowID: String = UUID().uuidString

    /// B16 — set for the Quick Terminal's window, which is summoned by a
    /// hotkey rather than opened by the user and is therefore neither
    /// saved into the arrangement nor listed as an ordinary window.
    var isQuickTerminal = false

    /// B16 — the lock in the titlebar while Secure Keyboard Entry is
    /// actually engaged for this window. Visible state is the point of the
    /// feature: the effect itself is invisible (keystrokes simply stop
    /// reaching other processes), so without an indicator a user cannot tell
    /// whether the password they are about to type is covered. It follows
    /// `SecureInput.engaged`, not the setting — the lock is open the moment
    /// another app is frontmost, and the titlebar says so.
    private var secureInputIndicator: NSTitlebarAccessoryViewController?
    private var secureInputObserver: NSObjectProtocol?

    override func windowDidLoad() {
        super.windowDidLoad()
        installSecureInputIndicator()
    }

    /// B16 — swaps the storyboard's `NSWindow` for a non-activating
    /// `NSPanel` carrying the same content, before the window is shown.
    ///
    /// **Why a panel.** An ordinary window ordered front by an application
    /// that is not active never reaches the screen while another
    /// application is full-screen: the window server keeps it on the
    /// desktop Space, `.canJoinAllSpaces` and `.fullScreenAuxiliary`
    /// notwithstanding, and `NSApp.activate()` is either refused (the
    /// hotkey is not an interaction the system credits to Corta) or, when
    /// it is honoured, drags the user out of the full-screen Space to
    /// wherever Corta's other windows are. Measured on macOS 27 with
    /// TextEdit full-screen: `kCGWindowIsOnscreen` stayed false for every
    /// `NSWindow` variant and became true for a `.nonactivatingPanel`,
    /// which can be key without the application being active. This is the
    /// panel class Spotlight-style overlays are made of, and the reason
    /// every terminal with a hotkey window uses one.
    ///
    /// The swap happens here, on the controller, because it is the one
    /// place that knows what `windowDidLoad` put on the old window (the
    /// secure-input lock) and has to put on the new one. Everything
    /// `SplitViewController.viewWillAppear` does — style flags, sizing,
    /// first responder — runs later against the panel, exactly as it
    /// would against the window.
    func adoptNonactivatingPanel() {
        guard let old = window, !(old is NSPanel) else { return }
        let panel = NSPanel(
            contentRect: old.contentRect(forFrameRect: old.frame),
            styleMask: old.styleMask.union(.nonactivatingPanel),
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // NSPanel hides itself when the application deactivates;
        // `QuickTerminalController` animates that dismissal and decides
        // whether focus goes back to the previous application.
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
        // Called once per window this controller has owned
        // (`adoptNonactivatingPanel`): the previous window's observer must
        // not keep updating an accessory on a window that is gone.
        if let secureInputObserver { NotificationCenter.default.removeObserver(secureInputObserver) }
        let image = NSImageView(
            image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = L10n.text("secureInput.indicator.tooltip")
        image.setAccessibilityLabel(L10n.text("secureInput.indicator.tooltip"))
        image.translatesAutoresizingMaskIntoConstraints = false
        // Sized by frame, not by constraints: AppKit places an accessory
        // view with autoresizing constraints of its own (a fixed 32pt
        // container height, a pinned origin), and a width/height
        // constraint on top of those was unsatisfiable — logged as
        // "Conflicting constraints detected" on every window until the
        // 2026-09-17 pass read the console. The frame is what the
        // titlebar reads for the accessory's width; the height follows
        // the titlebar.
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

    private func updateSecureInputIndicator() {
        guard let window else { return }
        secureInputIndicator?.isHidden = !(SecureInput.shared.engaged && window.isKeyWindow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let splitController else { return true }
        let running = splitController.panesWithRunningJobs
        return splitController.confirmClose(of: running, scope: L10n.text("close.scope.window"))
    }

    /// The layout this window would be restored as (M7.4). Read at quit and
    /// whenever a window closes, so state survives both routes.
    var restorableState: WindowState? {
        guard let window, let splitController, !isQuickTerminal else { return nil }
        var state = splitController.windowState(frame: window.frame)
        state?.id = windowID
        return state
    }
}
