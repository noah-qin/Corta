import Cocoa
import CortaTerminal

/// Text input into the PTY (Track A): paste, and the home of IME-committed
/// text once `TerminalView+IME.swift` lands.
extension ViewController {
    // MARK: - Paste (M2.6, app side)

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let sanitized = Paste.sanitized(text)
        guard !sanitized.isEmpty else { return }
        if Paste.needsWarning(text: sanitized, bracketedPasteEnabled: bracketedPasteEnabled()) {
            let alert = NSAlert()
            alert.messageText = L10n.text("paste.newlines.title")
            alert.informativeText =
                L10n.text("paste.newlines.message")
            alert.addButton(withTitle: L10n.text("common.paste"))
            alert.addButton(withTitle: L10n.text("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let payload = Paste.bytes(for: sanitized, bracketedPasteEnabled: bracketedPasteEnabled())
        // B03: bounded chunks, not one arbitrarily large enqueue — a
        // multi-megabyte paste sent as a single `write` would occupy the
        // one FIFO the writer queue shares with keyboard input for the
        // whole write, so a keystroke typed mid-paste would wait behind all
        // of it rather than behind one chunk.
        for chunk in Paste.chunked(payload) {
            switch session.write(chunk) {
            case .accepted:
                continue
            case .backpressured:
                // The child has stopped reading; the remaining chunks could
                // only be dropped too, so stop feeding them rather than
                // churn the queue for nothing, and say why the paste came up
                // short.
                terminalView?.showToast(L10n.text("toast.pasteStopped"), kind: .warning)
                return
            case .stopped:
                // The session is already gone (the pane is tearing down) —
                // nothing is reading this toast either, and "the shell isn't
                // reading input" would be a misleading thing to say about a
                // session that no longer exists at all.
                return
            }
        }
    }

    /// The Edit menu's Paste lands on `TerminalView.paste(_:)`; the context
    /// menu targets the pane controller directly, which is what this is for.
    @objc func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    /// The core's ?2004 bracketed-paste flag (M2.6). When on, pastes are
    /// wrapped in `ESC[200~`…`ESC[201~` and the newline warning is skipped.
    func bracketedPasteEnabled() -> Bool {
        session.isBracketedPasteEnabled
    }
}
