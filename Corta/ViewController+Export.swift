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

/// Writing the pane to a file, for output too large for the pasteboard.
/// The text is `Selection.text`, exactly what a copy gets: the selection if
/// there is one, else the whole document.
extension ViewController {
    /// The build is O(scrollback) — hundreds of ms for 100k lines
    /// (`PERFORMANCE.md` §5.2) — so it runs off the main thread, before the
    /// save panel, so empty text skips the panel. `largeTextTask` is cancelled
    /// by a newer export or `teardown()`, which stops the panel and write
    /// that follow; a row walk in progress still finishes.
    @objc func exportText(_ sender: Any?) {
        guard isOperable, let window = view.window, session != nil else { return }
        let grid = session.snapshot()
        let hasSelection = selection != nil
        let range = selection.map { selectionRange(for: $0, in: grid) }
        performExport(
            window: window, grid: grid, range: range,
            messageKey: hasSelection ? "export.message.selection" : "export.message.history",
            filename: Self.exportFilename(hasSelection: hasSelection))
    }

    /// The same export for `effectiveCommand`'s output.
    @objc func exportCommandOutput(_ sender: Any?) {
        guard isOperable, let window = view.window, session != nil else { return }
        let grid = session.snapshot()
        guard let range = Self.commandOutputRange(grid: grid, record: effectiveCommand) else {
            terminalView?.showToast(L10n.text("toast.noCommandOutput"), kind: .warning)
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

            enum Outcome {
                case cancelledOrDismissed
                case empty
                case wrote
                case failed(Error)
            }
            let outcome: Outcome
            if Task.isCancelled {
                outcome = .cancelledOrDismissed
            } else if text.isEmpty {
                outcome = .empty
            } else {
                // Lets cancellation dismiss the panel and resume at once; the
                // continuation alone has no cancellation awareness.
                let panelBox = PresentedPanelBox()
                let url: URL? = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            guard let self, !self.didTeardown,
                                self.largeTextTaskGeneration == generation
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
                if Task.isCancelled {
                    outcome = .cancelledOrDismissed
                } else if let url {
                    do {
                        try Self.write(text, to: url)
                        outcome = .wrote
                    } catch {
                        // Access was granted, so this is a full disk or read-only
                        // volume: alert, since the file doesn't exist.
                        outcome = .failed(error)
                    }
                } else {
                    outcome = .cancelledOrDismissed
                }
            }

            // One exit: clear the handle (generation-guarded) and apply.
            await MainActor.run {
                guard let self, !self.didTeardown, self.largeTextTaskGeneration == generation else { return }
                self.largeTextTask = nil
                switch outcome {
                case .cancelledOrDismissed:
                    break
                case .empty:
                    self.terminalView?.showToast(L10n.text("toast.nothingToExport"), kind: .warning)
                case .wrote:
                    self.terminalView?.showToast(L10n.text("toast.exported"))
                case .failed(let error):
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// The write, testable apart from the panel: UTF-8 with a trailing
    /// newline, which grep, less and diff expect.
    nonisolated static func write(_ text: String, to url: URL) throws {
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        try Data(payload.utf8).write(to: url, options: .atomic)
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

/// The presented panel, for `onCancel` to dismiss. `@unchecked Sendable`:
/// every access is on the main actor, `onCancel` included via its hop.
private final class PresentedPanelBox: @unchecked Sendable {
    var panel: NSSavePanel?
}
