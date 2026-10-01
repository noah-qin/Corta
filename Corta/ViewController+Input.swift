// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import CortaTerminal

/// Paste. IME commits arrive via `TerminalView+IME.swift`'s `insertText`.
extension ViewController {
    // MARK: - Paste

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
        returnToBottomOnInput()
        sendPaste(sanitized)
    }

    /// Queues a sanitised paste whole, or not at all. In pieces, a backlog
    /// that filled part-way stopped it after `ESC[200~` and before
    /// `ESC[201~`, and the shell — Claude Code, zsh — stayed in paste mode,
    /// taking every later Return as pasted text: the pane looked frozen.
    func sendPaste(_ sanitized: String) {
        let payload = Paste.bytes(for: sanitized, bracketedPasteEnabled: bracketedPasteEnabled())
        // Chunks, so the writer hands the child one at a time.
        switch session.write(chunks: Paste.chunked(payload)) {
        case .accepted:
            break
        case .backpressured:
            // The child stopped reading; nothing was sent. Say why.
            terminalView?.showToast(L10n.text("toast.pasteStopped"), kind: .warning)
        case .stopped:
            // The session is gone; nobody would read the toast.
            break
        }
    }

    /// For the context menu, which targets the controller.
    @objc func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    /// ?2004: wrap pastes in `ESC[200~`…`ESC[201~`, skip the newline warning.
    func bracketedPasteEnabled() -> Bool {
        session.isBracketedPasteEnabled
    }
}
