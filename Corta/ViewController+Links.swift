import Cocoa
import CortaTerminal

/// ⌘-click URL opening (M4.6). Detection and the scheme allowlist live in
/// the core (`LinkDetection.swift` — only `http`/`https`/`mailto` can ever
/// match); this file is hit-testing, hover feedback and the `NSWorkspace`
/// hand-off. Opening is always an explicit ⌘-click — nothing auto-opens
/// (`SECURITY.md` §2.4).
extension ViewController {
    /// ⌘-click on a link opens it and consumes the event; anything else
    /// returns `false` so the event continues to mouse reporting or
    /// selection.
    func handleLinkClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard event.modifierFlags.contains(.command),
            let link = linkUnder(event, in: terminalView),
            let url = URL(string: link.url),
            let scheme = url.scheme?.lowercased(),
            // Re-checked at the hand-off, not just in the detector's pattern:
            // this is the line between terminal output and another
            // application launching (`SECURITY.md` §2.4).
            ["http", "https", "mailto"].contains(scheme)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// ⌘-hover feedback: a pointing hand over a link, and a tooltip naming
    /// the real target before any click can open it (`SECURITY.md` §2.4).
    /// Called on mouse-moved and on ⌘ press/release.
    func handleLinkHover(_ event: NSEvent, in terminalView: TerminalView) {
        if event.modifierFlags.contains(.command),
            let link = linkUnder(event, in: terminalView)
        {
            NSCursor.pointingHand.set()
            if terminalView.toolTip != link.url { terminalView.toolTip = link.url }
        } else {
            NSCursor.arrow.set()
            if terminalView.toolTip != nil { terminalView.toolTip = nil }
        }
    }

    /// The link under the event, resolved through the same inset-aware,
    /// scroll-offset-aware mapping selection uses.
    private func linkUnder(_ event: NSEvent, in terminalView: TerminalView) -> LinkDetection.Link? {
        guard session != nil, terminalRenderer != nil else { return nil }
        let grid = session.snapshot()
        let point = documentPosition(for: event, in: terminalView, grid: grid)
        return LinkDetection.link(at: point, in: grid)
    }
}
