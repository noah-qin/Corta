import AppKit
import Carbon.HIToolbox

/// B16 — Secure Keyboard Entry, the switch Terminal.app and iTerm2 both
/// carry under the same name.
///
/// While it is engaged the window server stops delivering keystrokes to
/// anything but the focused application: no event tap, keylogger, macro
/// tool or accessibility client sees what is typed at a `sudo` or `ssh`
/// password prompt. `docs/SECURITY.md` §4 has the trade-off — it is
/// system-wide, so it also silences the tools a person may want, which is
/// why it is a setting rather than a default.
///
/// **Balanced by construction.** `EnableSecureEventInput` is a counter, not
/// a flag: every call has to be matched by `DisableSecureEventInput` or the
/// machine is left in secure mode after Corta quits, with nothing a user can
/// click to get out of it. This type is the only caller of either, holds
/// one bit of state (`engaged`), and computes what that bit should be from
/// three facts — the setting, whether Corta is the active application, and
/// whether a terminal window is key — every time any of them changes. The
/// counter therefore never goes above one, and `disengage()` at quit brings
/// it back to zero whatever else happened on the way out.
@MainActor
final class SecureInput {
    static let shared = SecureInput()

    /// The system calls, injectable so the state machine is testable
    /// without flipping the real machine's input mode in a test host.
    struct System {
        var enable: () -> Void
        var disable: () -> Void

        static let live = System(
            enable: { EnableSecureEventInput() },
            disable: { DisableSecureEventInput() })
    }

    private let system: System
    private var observers: [NSObjectProtocol] = []

    /// The three inputs, kept so a change to one recomputes against the
    /// current values of the other two.
    private(set) var wanted = false
    private(set) var applicationIsActive = false
    private(set) var terminalWindowIsKey = false

    /// Whether the counter is currently at one.
    private(set) var engaged = false

    /// Posted on the main queue whenever `engaged` changes, so the menu
    /// checkmark and the titlebar indicator follow the *actual* state, not
    /// the setting — a setting that is on while Corta is in the background
    /// is a lock that is, at that moment, open.
    static let didChange = Notification.Name("SecureInput.didChange")

    init(system: System = .live) {
        self.system = system
    }

    /// Starts following the app's activation and key-window changes, and
    /// applies the setting from the config file.
    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationIsActive = true; self?.reconcile() }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationIsActive = false; self?.reconcile() }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                let isTerminal = Self.isTerminalWindow(note.object)
                MainActor.assumeIsolated {
                    self?.terminalWindowIsKey = isTerminal
                    self?.reconcile()
                }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                // Only a terminal window resigning matters; a sheet or the
                // settings window resigning does not change whether a
                // terminal is key.
                guard Self.isTerminalWindow(note.object) else { return }
                MainActor.assumeIsolated {
                    self?.terminalWindowIsKey = false
                    self?.reconcile()
                }
            },
            center.addObserver(
                forName: ConfigurationStore.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySetting() }
            },
        ]
        applicationIsActive = NSApp.isActive
        terminalWindowIsKey = Self.isTerminalWindow(NSApp.keyWindow)
        applySetting()
    }

    /// The keyboard reaches a terminal only through a terminal window;
    /// Settings, the About panel and the SFTP browser hold text fields whose
    /// contents are not passwords typed at a prompt.
    nonisolated private static func isTerminalWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        // Window notifications are posted on the main thread, which is
        // where `windowController` may be read.
        return MainActor.assumeIsolated { window.windowController is TerminalWindowController }
    }

    private func applySetting() {
        update(wanted: ConfigurationStore.shared.configuration.secureKeyboardEntry)
    }

    /// The setting, as the config file has it. The menu item writes the file
    /// (`AppDelegate.toggleSecureKeyboardEntry`) and the file change lands
    /// here, so a hand edit and the menu are one path.
    func update(wanted: Bool) {
        self.wanted = wanted
        reconcile()
    }

    /// Test seam for the two facts that otherwise arrive by notification.
    func update(applicationIsActive: Bool, terminalWindowIsKey: Bool) {
        self.applicationIsActive = applicationIsActive
        self.terminalWindowIsKey = terminalWindowIsKey
        reconcile()
    }

    private var shouldBeEngaged: Bool { wanted && applicationIsActive && terminalWindowIsKey }

    private func reconcile() {
        let target = shouldBeEngaged
        guard target != engaged else { return }
        if target { system.enable() } else { system.disable() }
        engaged = target
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Releases the counter unconditionally — for `applicationWillTerminate`,
    /// where no further notification will arrive to do it.
    func disengage() {
        guard engaged else { return }
        system.disable()
        engaged = false
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
