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
        session.write(Paste.bytes(for: sanitized, bracketedPasteEnabled: bracketedPasteEnabled()))
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
