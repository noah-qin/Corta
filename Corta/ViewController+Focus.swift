import Cocoa
import CortaTerminal

/// M6.7 — focus reporting (`?1004`).
///
/// A child that has set the mode wants to know when the terminal gains or
/// loses focus: `CSI I` on focus in, `CSI O` on focus out. Neovim's
/// `autoread` uses it to re-read a file the moment you come back to the
/// window, and tmux's `focus-events` forwards it to whatever is running
/// inside. Both silently do nothing when the terminal never reports.
///
/// "Focused" here means what it means to the user: this pane holds the
/// keyboard *and* its window is key. A background window's panes are not
/// focused however recently one of them was clicked, and in a split only one
/// pane at a time is.
///
/// The reports are two fixed byte strings — no stream-supplied text is
/// involved anywhere in this path (`SECURITY.md` §2.1).
extension ViewController {
    private static let focusIn: [UInt8] = [0x1B, 0x5B, 0x49]  // CSI I
    private static let focusOut: [UInt8] = [0x1B, 0x5B, 0x4F]  // CSI O

    var hasUserFocus: Bool {
        isFocusedPane && (view.window?.isKeyWindow ?? false)
    }

    /// Sends a report only when the state actually changed. AppKit posts key
    /// and first-responder changes far more often than focus really moves —
    /// a menu opening, a sheet, a split re-laying out — and a child that
    /// reads a report as an event would see a stream of them.
    func reportFocusIfNeeded() {
        let focused = hasUserFocus
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        guard session.isFocusReportingEnabled else { return }
        session.write(focused ? Self.focusIn : Self.focusOut)
    }

    /// Wired in `viewDidLoad`. The notifications are per-window and this is
    /// a per-pane observer, so the object filter matters: without it every
    /// pane in every window would report on any window's key change.
    func observeWindowFocus() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowFocusChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowFocusChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        reportFocusIfNeeded()
        // The ring and its highlight are keyed to `hasUserFocus`, which this
        // changes even for the pane that stays `isFocusedPane` throughout —
        // cmd-tabbing away must drop the ring without moving focus within
        // the split.
        applyFocusAppearance()
    }
}
