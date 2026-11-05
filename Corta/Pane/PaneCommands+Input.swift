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
        view.onCycleTab = { [weak view] step in
            guard let controller = view?.window?.windowController as? TerminalWindowController,
                controller.tabs.count > 1
            else { return false }
            controller.selectAdjacentTab(offset: step)
            return true
        }
        view.onFileDrop = { [weak self] pasteboard in
            self?.receiveFileDrop(pasteboard) ?? false
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

    private func receiveFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let context = dropInputContext else {
            host?.terminalView?.showToast(L10n.text("drop.targetChanged"), kind: .warning)
            return false
        }
        fileDropRequest?.cancel()
        fileDropRequest = FileDropRequest.start(pasteboard) { [weak self] result in
            guard let self else { FileDropStorage.remove(result.directory); return }
            self.fileDropRequest = nil
            self.completeFileDrop(result, context: context)
        }
        guard fileDropRequest != nil else {
            host?.terminalView?.showToast(L10n.text("drop.failed"), kind: .warning)
            return false
        }
        return true
    }

    func completeFileDrop(_ result: FileDropRequest.Result, context: FileDropInputContext) {
        guard context == self.dropInputContext else {
            FileDropStorage.remove(result.directory)
            self.host?.terminalView?.showToast(L10n.text("drop.targetChanged"), kind: .warning)
            return
        }
        if let notice = result.notice { self.host?.terminalView?.showToast(notice, kind: .warning) }
        let text = Self.quotedDropText(result.urls.map(\.path))
        guard !text.isEmpty else { FileDropStorage.remove(result.directory); return }
        if let directory = result.directory {
            FileDropStorage.release(directory)
            droppedCopies.insert(directory)
        }
        insertAsPaste(text, validate: { [weak self] in
            guard context == self?.dropInputContext else {
                self?.host?.terminalView?.showToast(L10n.text("drop.targetChanged"), kind: .warning)
                return false
            }
            return true
        }, onDiscard: { [weak self] in
            if let directory = result.directory { self?.droppedCopies.remove(directory) }
            FileDropStorage.remove(result.directory)
        })
    }

    var dropInputContext: FileDropInputContext? {
        guard let session = host?.session, let group = session.pty.foregroundProcessGroup else { return nil }
        return FileDropInputContext(session: ObjectIdentifier(session), foregroundGroup: group)
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
    /// stripped, bracketed paste when asked, and the configured risk warning
    /// — service text and filenames can hold newlines or concealed scalars.
    func insertAsPaste(_ text: String, validate: (() -> Bool)? = nil, onDiscard: (() -> Void)? = nil) {
        guard validate?() != false, let host, host.session != nil else { onDiscard?(); return }
        let sanitized = Paste.sanitized(text)
        guard !sanitized.isEmpty else { onDiscard?(); return }
        guard !suppressPasteWarnings else { pasteNow(sanitized); return }
        let risks = Paste.warningRisks(
            in: text, bracketedPasteEnabled: bracketedPasteEnabled(),
            policy: ConfigurationStore.shared.configuration.pasteWarning)
        guard !risks.isEmpty else {
            pasteNow(sanitized)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("paste.warning.title")
        alert.informativeText = risks.map { L10n.text($0.localizationKey) }.joined(separator: "\n")
        alert.accessoryView = Self.pastePreview(sanitized)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.text("paste.warning.suppress")
        alert.addButton(withTitle: L10n.text("common.paste"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.present(for: host.view.window) { [weak self] response in
            // The pane may have closed while the sheet was up.
            guard response == .alertFirstButtonReturn, self?.host?.session != nil, validate?() != false
            else { onDiscard?(); return }
            if alert.suppressionButton?.state == .on { self?.suppressPasteWarnings = true }
            self?.pasteNow(sanitized)
        }
    }

    /// The text about to be pasted, its concealed scalars made visible, in a
    /// rounded scrolling box for the warning's accessory view.
    private static func pastePreview(_ text: String) -> NSView {
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        preview.isEditable = false
        preview.drawsBackground = false
        preview.textColor = .labelColor
        preview.textContainerInset = NSSize(width: 12, height: 10)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.string = Paste.visiblePreview(text)
        let scroll = NSScrollView(frame: preview.frame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = preview
        // Let AppKit resolve semantic colours for the sheet's appearance.
        // The transparent document and clip view keep the rounded surface
        // continuous while its text scrolls.
        let previewBox = NSBox(frame: scroll.frame)
        previewBox.boxType = .custom
        previewBox.titlePosition = .noTitle
        previewBox.contentViewMargins = .zero
        previewBox.cornerRadius = 10
        previewBox.borderWidth = 0.5
        previewBox.borderColor = .separatorColor
        previewBox.fillColor = .quaternaryLabelColor.withAlphaComponent(0.06)
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 10
        previewBox.layer?.masksToBounds = true
        previewBox.contentView = scroll
        return previewBox
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
            for: point, grid: grid, scrollOffset: host.scrollOffset,
            in: GridGeometry(viewHeight: terminalView.bounds.height, metrics: metrics, topInset: host.topInset))
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
        let outcome = session.write(
            paste: Paste.chunks(for: sanitized, bracketedPasteEnabled: bracketed),
            closing: Paste.closing(bracketedPasteEnabled: bracketed))
        switch outcome {
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

    /// ?2004: wrap pastes in `ESC[200~`…`ESC[201~`; content risks still warn.
    func bracketedPasteEnabled() -> Bool {
        host?.session?.isBracketedPasteEnabled ?? false
    }
}

/// A kernel foreground-group sample and object identity, never a process name.
/// Missing samples fail closed; an unrelated new session cannot inherit a drop.
nonisolated struct FileDropInputContext: Equatable {
    let session: ObjectIdentifier
    let foregroundGroup: Int32
}
