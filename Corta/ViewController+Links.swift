import Cocoa
import CortaTerminal

/// Opening URLs (M4.6, M7.9). Detection and the scheme allowlist live in
/// the core (`LinkDetection.swift` — only `http`/`https`/`mailto` can ever
/// match); this file is hit-testing, hover feedback and the `NSWorkspace`
/// hand-off.
///
/// **What a click costs.** ⌘-click is the default and always works: the
/// modifier is the confirmation, and nothing opens without one
/// (`SECURITY.md` §2.4). `link-activation = click` trades that modifier for
/// two other guards, which is what makes it a defensible option rather than a
/// hole: hovering a link *underlines* it and shows the real target in a
/// tooltip before any click is possible, and a plain click only opens on
/// mouse-up without movement, so dragging across a URL still selects it.
extension ViewController {
    /// Whether a plain click opens links in this pane.
    var opensLinksOnPlainClick: Bool {
        ConfigurationStore.shared.configuration.linkActivation == .click
    }

    /// ⌘-click on a link opens it and consumes the event; anything else
    /// returns `false` so the event continues to mouse reporting or
    /// selection. A plain click is deliberately not handled here — see
    /// `openLinkOnPlainClick`.
    func handleLinkClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        // U17 — a `path:line` reference, but only one that resolves to a file
        // on *this* machine. A URL wins where both could match: the other
        // detector already refuses to start inside one, so in practice they
        // do not overlap, and the order makes that explicit rather than
        // incidental.
        if let reference = fileReferenceUnder(event, in: terminalView) {
            return open(reference)
        }
        return false
    }

    /// The mouse-up half of `link-activation = click`: the click landed on a
    /// link and never moved, so it was a click on the link and not the start
    /// of a selection.
    @discardableResult
    func openLinkOnPlainClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard opensLinksOnPlainClick, !event.modifierFlags.contains(.shift)
        else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        if let reference = fileReferenceUnder(event, in: terminalView) {
            return open(reference)
        }
        return false
    }

    /// The hand-off. The scheme is re-checked here, not just in the
    /// detector's pattern: this is the line between terminal output and
    /// another application launching (`SECURITY.md` §2.4).
    private func open(_ link: LinkDetection.Link) -> Bool {
        guard let url = URL(string: link.url), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Hover feedback: a pointing hand over a link, an underline on the link
    /// itself, and a tooltip naming the real target before any click can open
    /// it (`SECURITY.md` §2.4). Called on mouse-moved and on ⌘ press/release.
    ///
    /// The cursor changes on transitions only. Setting it unconditionally
    /// on every mouse-moved fights `NSSplitView`'s resize cursor at a
    /// pane's divider edge — the two take turns within a single hover and
    /// the pointer visibly flickers (M5).
    func handleLinkHover(_ event: NSEvent, in terminalView: TerminalView) {
        // In ⌘-click mode nothing is a link until ⌘ is down, so nothing is
        // underlined either — the underline has to mean "this will open".
        let armed = opensLinksOnPlainClick || event.modifierFlags.contains(.command)
        if armed, session != nil, let link = linkUnder(event, in: terminalView) {
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            if terminalView.toolTip != link.url { terminalView.toolTip = link.url }
            setHoveredLink(link.range)
        } else if armed, session != nil,
            let reference = fileReferenceUnder(event, in: terminalView)
        {
            // U17 — the same "show the real target before it can be opened"
            // rule (`SECURITY.md` §2.4): the tooltip names the *resolved*
            // path, not the text under the pointer, so a relative path shows
            // where it actually leads. It also says when the line number will
            // be lost, which is the case with no `open-file-command` set.
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            let target = "\(reference.url.path):\(reference.line)"
            let tip =
                ConfigurationStore.shared.configuration.openFileCommand.isEmpty
                ? L10n.format("link.fileNoLine", target) : target
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(reference.range)
        } else {
            resetLinkHover(terminalView)
        }
    }

    /// Back to the arrow, no tooltip and no underline — but only if the hand
    /// is actually up, so an unlinked mouse-moved or mouse-exited costs
    /// nothing and never touches the cursor (see `handleLinkHover`).
    func resetLinkHover(_ terminalView: TerminalView) {
        if hoveringLink {
            NSCursor.arrow.set()
            hoveringLink = false
        }
        if terminalView.toolTip != nil { terminalView.toolTip = nil }
        if hoveredLink != nil {
            hoveredLink = nil
            invalidateDisplay()
        }
    }

    private func setHoveredLink(_ range: SelectionRange) {
        guard session != nil else { return }
        let highlight = TerminalSelection(range, grid: session.snapshot())
        guard !Self.sameRange(hoveredLink, highlight) else { return }
        hoveredLink = highlight
        invalidateDisplay()
    }

    private static func sameRange(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.start == b.start && a.end == b.end
            && a.baseScrollbackTotal == b.baseScrollbackTotal
    }

    /// The link under the event, resolved through the same inset-aware,
    /// scroll-offset-aware mapping selection uses.
    private func linkUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> LinkDetection.Link?
    {
        guard session != nil, terminalRenderer != nil else { return nil }
        let grid = session.snapshot()
        let point = documentPosition(for: event, in: terminalView, grid: grid)
        return LinkDetection.link(at: point, in: grid)
    }
}
