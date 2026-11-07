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
        view.canProvideServicesSelection = { [weak self] in
            self?.selectionForServices() != nil
        }
        view.onServicesSelection = { [weak self] in
            guard let (grid, range) = self?.selectionForServices() else { return nil }
            let text = Selection.text(of: range, in: grid)
            return text.isEmpty ? nil : text
        }
        view.onServicesInsert = { [weak self] text in
            self?.insertAsPaste(text)
        }
    }

    /// One reception per pane, the newest: two would fill their paths with
    /// nothing between them, and a stalled provider must not hold the pane
    /// until its deadline. A drop that cannot start replaces nothing.
    func receiveFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let context = dropInputContext else {
            host?.terminalView?.showToast(L10n.text("drop.targetChanged"), kind: .warning)
            return false
        }
        let request = FileDropRequest.start(pasteboard) { [weak self] result in
            guard let self else { FileDropStorage.remove(result.directory); return }
            self.fileDropRequest = nil
            self.completeFileDrop(result, context: context)
        }
        guard let request else {
            let notice = fileDropRequest == nil ? "drop.failed" : "drop.notStarted"
            host?.terminalView?.showToast(L10n.text(notice), kind: .warning)
            return false
        }
        if let earlier = fileDropRequest {
            earlier.cancel()
            host?.terminalView?.showToast(L10n.text("drop.replaced"), kind: .warning)
        }
        fileDropRequest = request
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
        if let directory = result.directory { droppedCopies.insert(directory) }
        insertAsPaste(text, validate: { [weak self] in
            guard context == self?.dropInputContext else {
                self?.host?.terminalView?.showToast(L10n.text("drop.targetChanged"), kind: .warning)
                return false
            }
            return true
        }, onDiscard: { [weak self] in
            if let directory = result.directory {
                self?.droppedCopies.remove(directory)
                FileDropStorage.release(directory)
            }
            FileDropStorage.remove(result.directory)
        }, onSent: {
            // Pinned until now: Clean Now must not take the copies out from
            // under a warning that is still asking whether to name them.
            if let directory = result.directory { FileDropStorage.release(directory) }
        })
    }

    var dropInputContext: FileDropInputContext? {
        guard let session = host?.session, let group = session.pty.foregroundProcessGroup else { return nil }
        return FileDropInputContext(session: session.id, foregroundGroup: group)
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

    /// One paste on its way from the pasteboard to a session: which session it
    /// was asked for, and what `?2004` said when it was judged.
    struct PasteDelivery {
        let session: TerminalSession
        /// Read once. The risks were judged by it and the bytes are encoded by
        /// it, so output cannot change one without the other.
        let bracketed: Bool
        let warns: Bool
        let validate: (() -> Bool)?
        let onDiscard: (() -> Void)?
        let onSent: (() -> Void)?
    }

    /// Drops and Services go down the ⌘V path (`SECURITY.md` §2.3): C0
    /// stripped, bracketed paste when asked, and the configured risk warning
    /// — service text and filenames can hold newlines or concealed scalars.
    ///
    /// Too large is refused before any of it is walked. Small text is judged
    /// here, keeping its place among the keystrokes around it; larger text off
    /// the main thread, where a newer paste replaces it.
    func insertAsPaste(
        _ text: String, validate: (() -> Bool)? = nil, onDiscard: (() -> Void)? = nil, onSent: (() -> Void)? = nil
    ) {
        cancelPasteScan()
        guard validate?() != false, let session = host?.session, !session.isStopped else { onDiscard?(); return }
        // UTF-16 first: O(1) on the pasteboard's bridged string, and never more
        // than the UTF-8 count it stands in for.
        guard text.utf16.count <= Paste.maximumBytes, text.utf8.count <= Paste.maximumBytes else {
            host?.terminalView?.showToast(L10n.text("toast.pasteTooLarge"), kind: .warning)
            onDiscard?()
            return
        }
        let policy = ConfigurationStore.shared.configuration.pasteWarning
        let delivery = PasteDelivery(
            session: session, bracketed: session.isBracketedPasteEnabled,
            warns: !suppressPasteWarnings && policy != .off,
            validate: validate, onDiscard: onDiscard, onSent: onSent)
        guard text.utf8.count >= Paste.synchronousScanLimit else {
            let risks =
                delivery.warns
                ? Paste.warningRisks(in: text, bracketedPasteEnabled: delivery.bracketed, policy: policy) : []
            decide(Paste.sanitized(text), risks: risks, delivery: delivery)
            return
        }
        scanPaste(text, policy: policy, delivery: delivery)
    }

    /// The scan off the main thread. Nothing comes back of one this has since
    /// replaced, and what does come back is checked against its session again.
    private func scanPaste(_ text: String, policy: Configuration.PasteWarning, delivery: PasteDelivery) {
        nextPasteScanID += 1
        let id = nextPasteScanID
        let (warns, bracketed) = (delivery.warns, delivery.bracketed)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let sanitized = Paste.sanitized(text)
            let risks =
                warns
                ? Paste.warningRisks(
                    in: text, bracketedPasteEnabled: bracketed, policy: policy,
                    shouldStop: { Task.isCancelled }) : []
            await self?.finishPasteScan(id, sanitized: sanitized, risks: risks, delivery: delivery)
        }
        pasteScan = PasteScan(id: id, task: task, onDiscard: delivery.onDiscard)
        // Silence for a moment, then an explanation of what is taking so long.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pasteScanNoticeDelay, clock: .suspending)
            guard let self, self.pasteScan?.id == id else { return }
            self.host?.terminalView?.showToast(L10n.text("toast.pasteChecking"))
        }
    }

    private func finishPasteScan(
        _ id: Int, sanitized: String, risks: [Paste.PasteRisk], delivery: PasteDelivery
    ) {
        guard pasteScan?.id == id else { return }
        pasteScan = nil
        decide(sanitized, risks: risks, delivery: delivery)
    }

    /// A scan still running gives way: its text is not sent, and whoever asked
    /// for it hears so.
    func cancelPasteScan() {
        guard let scan = pasteScan else { return }
        pasteScan = nil
        scan.task.cancel()
        scan.onDiscard?()
    }

    /// Sends the text, or asks first when it has risks to name.
    private func decide(_ sanitized: String, risks: [Paste.PasteRisk], delivery: PasteDelivery) {
        guard !sanitized.isEmpty else { delivery.onDiscard?(); return }
        guard !risks.isEmpty, let host else { deliver(sanitized, risks: risks, delivery: delivery); return }
        if let answer = pasteWarningAnswer {
            guard answer(risks) else { delivery.onDiscard?(); return }
            deliver(sanitized, risks: risks, delivery: delivery)
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
            guard let self, response == .alertFirstButtonReturn else { delivery.onDiscard?(); return }
            if alert.suppressionButton?.state == .on { self.suppressPasteWarnings = true }
            self.deliver(sanitized, risks: risks, delivery: delivery)
        }
    }

    /// The last check before the bytes go: the sheet or the scan took time, and
    /// any of it may have changed. The pane may have closed, or been rebuilt
    /// with a new session this text was never meant for. And `?2004` is the
    /// child's to change: text judged safe because it would arrive marked must
    /// not go unmarked, its newlines then Returns, so it is asked about again.
    func deliver(_ sanitized: String, risks: [Paste.PasteRisk], delivery: PasteDelivery) {
        guard let host, host.session === delivery.session, !delivery.session.isStopped,
            delivery.validate?() != false
        else { delivery.onDiscard?(); return }
        let live = delivery.session.isBracketedPasteEnabled
        if delivery.warns, delivery.bracketed, !live, Paste.containsNewline(sanitized) {
            let judgedAgain = PasteDelivery(
                session: delivery.session, bracketed: false, warns: true, validate: delivery.validate,
                onDiscard: delivery.onDiscard, onSent: delivery.onSent)
            decide(sanitized, risks: risks.filter { $0 != .multiline } + [.multiline], delivery: judgedAgain)
            return
        }
        // Nothing warns here, by choice: nothing was judged, so nothing to keep to.
        let bracketed = delivery.warns ? delivery.bracketed : live
        delivery.onSent?()
        (host as? TerminalPaneViewController)?.updateReaderPriority(input: true)
        host.pointer.returnToBottomOnInput()
        sendPaste(sanitized, bracketed: bracketed, to: delivery.session)
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

    /// The selection's text, or nil when there is none or it is empty.
    func selectedText() -> String? {
        guard let (grid, range) = selectionSnapshot() else { return nil }
        let text = Selection.text(of: range, in: grid)
        return text.isEmpty ? nil : text
    }

    func selectionSnapshot() -> (Grid, SelectionRange)? {
        guard let host, host.selection != nil, let session = host.session else { return nil }
        let grid = session.snapshot()
        host.pointer.dropSelectionIfRewritten(in: grid)
        guard let selection = host.selection else { return nil }
        return (grid, host.pointer.selectionRange(for: selection, in: grid))
    }

    private func selectionForServices() -> (Grid, SelectionRange)? {
        guard let (grid, range) = selectionSnapshot() else { return nil }
        // AppKit requests Services text synchronously. Bound the work here;
        // Copy and Export can build a larger selection in the background.
        let rows = range.end.row - range.start.row
        let cells = rows * grid.columns + range.end.column - range.start.column + 1
        return cells <= 16_384 ? (grid, range) : nil
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
    /// Once queued, Ctrl-C may drop the rest (`TerminalView.onKeyBytes`);
    /// a paste the child started reading is then closed with `ESC[201~`.
    /// Saying so when the child is not reading, rather than dropping it
    /// without a word.
    private func sendPaste(_ sanitized: String, bracketed: Bool, to session: TerminalSession) {
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

/// A kernel foreground-group sample and session identity, never a process name.
/// Missing samples fail closed; an unrelated new session cannot inherit a drop.
nonisolated struct FileDropInputContext: Equatable {
    /// `TerminalSession.id`, never reused: an address can be, by the session
    /// that replaced this one.
    let session: UUID
    let foregroundGroup: Int32
}
