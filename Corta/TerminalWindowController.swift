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

    private func installSecureInputIndicator() {
        guard let window else { return }
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
        return splitController.confirmClose(of: running, scope: "this window")
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
