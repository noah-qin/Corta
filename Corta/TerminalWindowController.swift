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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let splitController else { return true }
        let running = splitController.panesWithRunningJobs
        return splitController.confirmClose(of: running, scope: "this window")
    }

    /// The layout this window would be restored as (M7.4). Read at quit and
    /// whenever a window closes, so state survives both routes.
    var restorableState: WindowState? {
        guard let window, let splitController else { return nil }
        return splitController.windowState(frame: window.frame)
    }
}
