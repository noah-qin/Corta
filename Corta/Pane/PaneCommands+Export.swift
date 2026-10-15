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
import UniformTypeIdentifiers

extension PaneCommands {
    // MARK: - Copy

    /// ⌘C through the responder chain; never reaches the PTY. The text build
    /// is O(selection) — the whole document for ⌘A — so it runs off the main
    /// actor on `largeTextTask`, like `exportText(_:)`.
    @objc func copy(_: Any?) {
        guard let host, let selection = host.selection, let session = host.session else { return }
        let grid = session.snapshot()
        let range = host.pointer.selectionRange(for: selection, in: grid)
        // The pasteboard is shared by every pane and app: recheck `changeCount`
        // before writing so a slow copy never clobbers a newer write.
        let changeCountAtStart = pasteboard.changeCount
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // `.detached`, so the build is off the main actor by construction
        // rather than by inference; the pasteboard write hops back.
        let buildText = buildSelectionText
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text = buildText(range, grid)
            await MainActor.run {
                // Only this generation may clear the handle a newer copy installed.
                guard let self, self.host?.didTeardown == false,
                    self.largeTextTaskGeneration == generation
                else { return }
                self.largeTextTask = nil
                guard !Task.isCancelled, !text.isEmpty else { return }
                let pasteboard = self.pasteboard
                guard pasteboard.changeCount == changeCountAtStart else {
                    // Someone wrote since; their write is newer than this selection.
                    return
                }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Confirm only a write that happened: copy-on-select is never silent.
                self.host?.terminalView?.showToast(L10n.text("toast.copied"))
            }
        }
    }

    // MARK: - Export

    /// Writes the pane to a file, for output too large for the pasteboard.
    /// The text is `Selection.text`, exactly what a copy gets: the selection
    /// if there is one, else the whole document.
    ///
    /// The build is O(scrollback) — hundreds of ms for 100k lines
    /// (`PERFORMANCE.md` §5.2) — so it runs off the main thread, before the
    /// save panel, so empty text skips the panel. `largeTextTask` is cancelled
    /// by a newer export or `stop()`, which stops the panel and write that
    /// follow; a row walk in progress still finishes.
    @objc func exportText(_: Any?) {
        guard let host, host.isOperable, let window = host.view.window else { return }
        let grid = host.session.snapshot()
        let selection = host.selection
        let range = selection.map { host.pointer.selectionRange(for: $0, in: grid) }
        performExport(
            window: window, grid: grid, range: range,
            messageKey: selection != nil ? "export.message.selection" : "export.message.history",
            filename: Self.exportFilename(hasSelection: selection != nil))
    }

    /// The same export for `effectiveCommand`'s output.
    @objc func exportCommandOutput(_: Any?) {
        guard let host, host.isOperable, let window = host.view.window else { return }
        let grid = host.session.snapshot()
        guard let range = PaneShellIntegration.commandOutputRange(grid: grid, record: host.effectiveCommand)
        else {
            host.terminalView?.showToast(L10n.text("toast.noCommandOutput"), kind: .warning)
            return
        }
        performExport(
            window: window, grid: grid, range: range, messageKey: "export.message.command",
            filename: Self.exportFilename(kind: "Command Output"))
    }

    /// The flow both exports share (see `exportText`).
    private func performExport(
        window: NSWindow, grid: Grid, range: SelectionRange?, messageKey: String, filename: String
    ) {
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // Detached, as in `copy(_:)`; AppKit calls hop back to the main actor
        // explicitly.
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self] in
            let text = Self.exportableText(grid: grid, selection: range)
            let outcome: ExportOutcome
            if Task.isCancelled {
                outcome = .cancelledOrDismissed
            } else if text.isEmpty {
                outcome = .empty
            } else {
                let url = await self?.exportDestination(
                    in: window, filename: filename, messageKey: messageKey, generation: generation)
                outcome = Self.export(text, to: url)
            }
            // One exit: clear the handle (generation-guarded) and apply.
            await MainActor.run {
                guard let self, self.host?.didTeardown == false,
                    self.largeTextTaskGeneration == generation
                else { return }
                self.largeTextTask = nil
                self.report(outcome, in: window)
            }
        }
    }

    private enum ExportOutcome {
        case cancelledOrDismissed
        case empty
        case wrote
        case failed(Error)
    }

    /// Where the user saves the export, from a sheet on `window`; `nil` when
    /// dismissed, superseded or cancelled. Cancellation dismisses the panel
    /// and resumes at once; the continuation alone has no cancellation
    /// awareness.
    nonisolated private func exportDestination(
        in window: NSWindow, filename: String, messageKey: String, generation: Int
    ) async -> URL? {
        let panelBox = PresentedPanelBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard self.host?.didTeardown == false, self.largeTextTaskGeneration == generation
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = filename
                    panel.canCreateDirectories = true
                    panel.isExtensionHidden = false
                    panel.message = L10n.text(messageKey)
                    panelBox.panel = panel
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                }
            }
        } onCancel: {
            // Accepted race: `onCancel` can run before the panel is
            // stored, and then the panel still shows. Closing it needs an
            // atomic handoff not worth it for a window this small.
            Task { @MainActor in
                guard let panel = panelBox.panel else { return }
                window.endSheet(panel, returnCode: .cancel)
            }
        }
    }

    /// Writes `text` to the chosen `url`, unless the task was cancelled or
    /// nothing was chosen.
    nonisolated private static func export(_ text: String, to url: URL?) -> ExportOutcome {
        guard !Task.isCancelled, let url else { return .cancelledOrDismissed }
        do {
            try write(text, to: url)
            return .wrote
        } catch {
            // Access was granted, so this is a full disk or read-only
            // volume: alert, since the file doesn't exist.
            return .failed(error)
        }
    }

    private func report(_ outcome: ExportOutcome, in window: NSWindow) {
        switch outcome {
        case .cancelledOrDismissed:
            break
        case .empty:
            host?.terminalView?.showToast(L10n.text("toast.nothingToExport"), kind: .warning)
        case .wrote:
            host?.terminalView?.showToast(L10n.text("toast.exported"))
        case .failed(let error):
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    /// The write, testable apart from the panel: UTF-8 with a trailing
    /// newline, which grep, less and diff expect. Owner-only, like every file
    /// Corta writes from the terminal: scrollback holds tokens, and the umask's
    /// `0644` let any account that can reach the folder read the transcript.
    nonisolated static func write(_ text: String, to url: URL) throws {
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        try PrivateFile.write(Data(payload.utf8), to: url)
    }

    /// The selection or the whole document; pure, for tests.
    nonisolated static func exportableText(grid: Grid, selection: SelectionRange?) -> String {
        if let selection { return Selection.text(of: selection, in: grid) }
        // As ⌘A: the scrollback's first row is `-scrollback.count`.
        let whole = SelectionRange(
            anchor: SelectionPoint(row: -grid.scrollback.count, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1))
        return Selection.text(of: whole, in: grid)
    }

    nonisolated static func exportFilename(hasSelection: Bool, date: Date = Date()) -> String {
        exportFilename(kind: hasSelection ? "Selection" : "History", date: date)
    }

    nonisolated static func exportFilename(kind: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Corta \(kind) \(formatter.string(from: date)).txt"
    }
}
