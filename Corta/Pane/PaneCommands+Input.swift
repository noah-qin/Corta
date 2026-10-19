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

import AppKit
import CortaTerminal

extension PaneCommands {
    // MARK: - Pinch, paste, drops, Services and Look Up

    func installNativeIntegrations(on view: TerminalView) {
        view.onMagnify = { [weak self] magnification in
            self?.magnify(by: magnification)
        }
        view.onMagnifyEnded = { [weak self] in
            self?.endMagnification()
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
        view.onDropPaths = { [weak self] paths in
            self?.insertDroppedPaths(paths)
        }
        view.onLookUp = { [weak self] point in
            self?.wordForLookUp(at: point)
        }
        view.onServicesSelection = { [weak self] in
            self?.selectedText()
        }
        view.onServicesInsert = { [weak self] text in
            self?.insertAsPaste(text)
        }
    }

    /// Dropped paths arrive at the prompt shell-quoted, as if typed.
    private func insertDroppedPaths(_ paths: [String]) {
        let text = Self.quotedDropText(paths)
        guard !text.isEmpty else { return }
        // No trailing space: the user may keep typing the path.
        insertAsPaste(text)
    }

    /// One space-separated, quoted run. Each path is sanitised first (a name
    /// can hold ESC or a newline); an emptied path is dropped.
    static func quotedDropText(_ paths: [String]) -> String {
        paths.map { Paste.sanitized($0) }
            .filter { !$0.isEmpty }
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    /// Single-quoted for any shell the pane may be running. Filenames can
    /// carry `;`, backticks or `$(…)`, and this text goes to a shell, so
    /// quoting makes the printable remainder inert (controls are already
    /// gone). Not POSIX's `'\''`: inside fish's single quotes `\'` and `\\`
    /// are escapes, so `x\'; cmd; \'` broke out and ran `cmd`. `'` and `\`
    /// are each written double-quoted between single-quoted runs — `"'"` and
    /// `"\\"` read the same in sh, bash, zsh and fish.
    ///
    /// The walk is by scalar, not `Character`: a shell reads bytes, and `'`
    /// followed by a combining mark (U+0301, a ZWJ) is one grapheme cluster
    /// that compares unequal to `"'"` — matched by `Character`, its quote went
    /// out raw and closed the run.
    static func shellQuoted(_ path: String) -> String {
        // A deliberately narrow set may go unquoted.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@:+")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in path.unicodeScalars {
            switch scalar {
            case "'": quoted.append(contentsOf: #"'"'"'"#.unicodeScalars)
            case "\\": quoted.append(contentsOf: #"'"\\"'"#.unicodeScalars)
            default: quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
    }

    /// Drops and Services go down the ⌘V path (`SECURITY.md` §2.3): C0
    /// stripped, bracketed paste when asked, and a newline warning without
    /// `?2004` — service text and filenames can hold newlines.
    func insertAsPaste(_ text: String) {
        guard let host, host.session != nil else { return }
        let sanitized = Paste.sanitized(text)
        guard !sanitized.isEmpty else { return }
        guard Paste.needsWarning(text: sanitized, bracketedPasteEnabled: bracketedPasteEnabled()) else {
            pasteNow(sanitized)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("paste.newlines.title")
        alert.informativeText = L10n.text("paste.newlines.message")
        alert.addButton(withTitle: L10n.text("common.paste"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.present(for: host.view.window) { [weak self] response in
            // The pane may have closed while the sheet was up.
            guard response == .alertFirstButtonReturn, self?.host?.session != nil else { return }
            self?.pasteNow(sanitized)
        }
    }

    /// A paste in every way that matters, as in `pasteFromClipboard` —
    /// including saying so when the child is not reading, rather than
    /// dropping the drop without a word.
    private func pasteNow(_ sanitized: String) {
        (host as? ViewController)?.updateReaderPriority(input: true)
        host?.pointer.returnToBottomOnInput()
        sendPaste(sanitized)
    }

    /// The selection's text, or nil when there is none or it is empty.
    func selectedText() -> String? {
        guard let host, host.selection != nil, let session = host.session else { return nil }
        let grid = session.snapshot()
        host.pointer.dropSelectionIfRewritten(in: grid)
        guard let selection = host.selection else { return nil }
        let text = Selection.text(of: host.pointer.selectionRange(for: selection, in: grid), in: grid)
        return text.isEmpty ? nil : text
    }

    /// The word under a force touch, anchored at the cell's origin so the
    /// popover points at the word.
    func wordForLookUp(at point: CGPoint) -> (String, CGPoint)? {
        guard let host, let session = host.session, let terminalRenderer = host.terminalRenderer,
            let terminalView = host.terminalView
        else { return nil }
        let grid = session.snapshot()
        let metrics = terminalRenderer.pointMetrics
        let position = PanePointer.documentPosition(
            for: point, viewHeight: terminalView.bounds.height,
            metrics: metrics, grid: grid,
            scrollOffset: host.scrollOffset, topInset: host.topInset)
        let range = Selection.range(at: position, unit: .word, in: grid)
        let text = Selection.text(of: range, in: grid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let origin = CGPoint(
            x: TerminalLayout.insets.left + CGFloat(range.start.column) * metrics.cellWidth,
            y: point.y)
        return (text, origin)
    }

    // MARK: - Paste

    /// ⌘V: the one paste path drops and Services also take
    /// (`insertAsPaste`).
    func pasteFromClipboard() {
        guard let text = pasteboard.string(forType: .string) else { return }
        insertAsPaste(text)
    }

    /// Queues a sanitised paste whole, or not at all — admitted part-way, a
    /// backlog stopped it after `ESC[200~` and before `ESC[201~`, and the
    /// shell stayed in paste mode, taking every later Return as pasted text.
    /// Once queued, Ctrl-C may drop the rest (`ViewController.onKeyBytes`);
    /// a paste the child started reading is then closed with `ESC[201~`.
    func sendPaste(_ sanitized: String) {
        let bracketed = bracketedPasteEnabled()
        guard let session = host?.session else { return }
        switch session.write(
            paste: Paste.chunks(for: sanitized, bracketedPasteEnabled: bracketed),
            closing: Paste.closing(bracketedPasteEnabled: bracketed))
        {
        case .accepted:
            host?.terminalView?.noteUserInput()
        case .backpressured:
            // The child stopped reading; nothing was sent. Say why.
            host?.terminalView?.showToast(L10n.text("toast.pasteStopped"), kind: .warning)
        case .stopped, .failed:
            // The session is gone; nobody would read the toast.
            break
        }
    }

    /// ⌘V, and the context menu.
    @objc func paste(_: Any?) {
        pasteFromClipboard()
    }

    /// ?2004: wrap pastes in `ESC[200~`…`ESC[201~`, skip the newline warning.
    func bracketedPasteEnabled() -> Bool {
        host?.session?.isBracketedPasteEnabled ?? false
    }
}
