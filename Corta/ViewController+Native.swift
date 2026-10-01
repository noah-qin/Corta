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

/// Drops, force touch and Services.
extension ViewController {
    func installNativeIntegrations(on view: TerminalView) {
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
    static func shellQuoted(_ path: String) -> String {
        // A deliberately narrow set may go unquoted.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@:+")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        var quoted = "'"
        for character in path {
            switch character {
            case "'": quoted += #"'"'"'"#
            case "\\": quoted += #"'"\\"'"#
            default: quoted.append(character)
            }
        }
        return quoted + "'"
    }

    /// Drops and Services go down the ⌘V path (`SECURITY.md` §2.3): C0
    /// stripped, bracketed paste when asked, and a newline warning without
    /// `?2004` — service text and filenames can hold newlines.
    func insertAsPaste(_ text: String) {
        guard session != nil else { return }
        let sanitized = Paste.sanitized(text)
        guard !sanitized.isEmpty else { return }
        if Paste.needsWarning(
            text: sanitized, bracketedPasteEnabled: session.isBracketedPasteEnabled)
        {
            let alert = NSAlert()
            alert.messageText = L10n.text("paste.newlines.title")
            alert.informativeText = L10n.text("paste.newlines.message")
            alert.addButton(withTitle: L10n.text("common.paste"))
            alert.addButton(withTitle: L10n.text("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // A paste in every way that matters, as in `pasteFromClipboard` —
        // including saying so when the child is not reading, rather than
        // dropping the drop without a word.
        returnToBottomOnInput()
        sendPaste(sanitized)
    }

    func selectedText() -> String? {
        guard let selection, session != nil else { return nil }
        let grid = session.snapshot()
        let text = Selection.text(of: selectionRange(for: selection, in: grid), in: grid)
        return text.isEmpty ? nil : text
    }

    /// The word under a force touch, anchored at the cell's origin so the
    /// popover points at the word.
    func wordForLookUp(at point: CGPoint) -> (String, CGPoint)? {
        guard session != nil else { return nil }
        let grid = session.snapshot()
        let position = Self.documentPosition(
            for: point, viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, grid: grid,
            scrollOffset: scrollOffset, topInset: topInset)
        let range = Selection.range(at: position, unit: .word, in: grid)
        let text = Selection.text(of: range, in: grid)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let metrics = terminalRenderer.pointMetrics
        let origin = CGPoint(
            x: TerminalLayout.insets.left + CGFloat(range.start.column) * metrics.cellWidth,
            y: point.y)
        return (text, origin)
    }
}
