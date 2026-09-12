import AppKit
import CortaTerminal
import UniformTypeIdentifiers

/// U15 — writing what is in the pane to a file.
///
/// **Why a file and not just the clipboard.** ⌘C already exists, and for a
/// line or two it is the right tool. A hundred thousand lines of build output
/// is not something anybody wants on the pasteboard on the way to a bug
/// report: it has to survive the next copy, be attachable, and be greppable.
/// This is the same text the clipboard would get — `Selection.text` over the
/// same range, so a soft-wrapped line exports as one line exactly as it
/// copies as one — written where the user says.
///
/// **What gets written.** The selection if there is one, the whole document
/// (scrollback plus screen) if there is not. That is the rule the Edit menu's
/// Copy already follows one level down, and it means the command needs no
/// second name and no submenu: what you have selected is what you get.
extension ViewController {
    /// B05: building the text is O(scrollback) — the same cost class
    /// `PERFORMANCE.md` §5.2 measures a full-document search sweep at
    /// hundreds of ms for a 100k-line history — so it runs off the main
    /// thread rather than stalling the interaction path. The build runs
    /// *before* the save panel appears — trading the earlier "overlap the
    /// build with panel navigation time" version's speed for two things
    /// that version broke: an empty document or selection now skips the
    /// panel entirely again (present a save dialog, only to say "nothing to
    /// export," is worse than a moment's wait first), and there is no build
    /// left running unobserved once the panel is up for the user to answer.
    /// `largeTextTask` is cancelled by a superseded export (a second ⌘⇧S
    /// before the first panel closed) and by `teardown()` — but, like
    /// `copy(_:)`, only ever to stop a *result* from being applied.
    /// `exportableText`/`Selection.text` poll no cancellation flag
    /// internally, so a row walk already in progress when cancellation
    /// arrives runs to completion regardless; what stops there is the
    /// panel that would follow it, and the write/toast/alert that would
    /// follow that.
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

    /// B07 — the same export, scoped to `effectiveCommand`'s output rather
    /// than the current selection: the identity-based counterpart to
    /// `copyLastCommandOutput`, for a build log too long to want on the
    /// clipboard but still worth attaching to a bug report.
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

    /// The save-panel/write flow both `exportText` and `exportCommandOutput`
    /// share — see `exportText`'s doc comment above for why the build runs
    /// off the main thread and why cancellation is generation-guarded rather
    /// than relied on to always land before a result is applied.
    private func performExport(
        window: NSWindow, grid: Grid, range: SelectionRange?, messageKey: String, filename: String
    ) {
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // `Task.detached`, not a plain `Task {}` — see `copy(_:)`'s identical
        // reasoning: this method is `@MainActor`, and relying on a
        // nonisolated callee to implicitly escape an inherited actor is the
        // fragile inference Copilot's review flagged. Every AppKit call
        // below (`NSSavePanel`, `NSAlert`) is explicitly hopped back to
        // `MainActor` rather than assumed to still be there.
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
                // A live handle to the presented panel, so cancellation —
                // teardown, or a superseded export — can dismiss it and
                // resume the continuation immediately instead of leaving
                // this task (and the build it already finished) suspended
                // until whenever the user happens to answer the sheet.
                // `withCheckedContinuation` itself has no cancellation
                // awareness; `withTaskCancellationHandler` is what supplies
                // it, wrapping the same continuation.
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
                    // Known, accepted narrow race: `onCancel` can run
                    // before the presentation `Task` above has reached
                    // `panelBox.panel = panel` — both the guard and that
                    // assignment happen without an `await` between them,
                    // but they are still two separate MainActor hops, and
                    // nothing serializes which one this runs relative to.
                    // In that exact window `panelBox.panel` reads `nil`
                    // and there is nothing to dismiss yet; the presentation
                    // continues (its own generation/`didTeardown` guard
                    // already passed) and shows a panel this cancellation
                    // cannot then retract. Closing that gap needs an
                    // atomic handoff between the two, which is more
                    // machinery than a window measured in a handful of
                    // synchronous instructions has earned here.
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
                        // The panel already granted access, so a failure
                        // here is a full disk or a read-only volume — worth
                        // an alert rather than a toast, because the file the
                        // user asked for does not exist and nothing else
                        // would say so.
                        outcome = .failed(error)
                    }
                } else {
                    outcome = .cancelledOrDismissed
                }
            }

            // One exit point: clears the handle (generation-guarded, same
            // reasoning as `copy(_:)`) and applies the outcome together,
            // rather than an early `return` per case that each had to
            // remember to clear it too.
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

    /// The write itself, separated from the panel so the bytes that land on
    /// disk are testable — the panel is AppKit's and is not in doubt, the
    /// encoding and the trailing newline are ours (U15).
    ///
    /// UTF-8, and a trailing newline when the text does not already end in
    /// one: the file is going to be read by `grep`, `less` and a diff, and
    /// every one of them treats a file without a final newline as malformed.
    nonisolated static func write(_ text: String, to url: URL) throws {
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    /// The text a save would write: the selection, or the whole document.
    ///
    /// Static and pure so the range arithmetic is testable without a window
    /// or a save panel — the part that can be wrong is which rows are chosen,
    /// not that `NSSavePanel` works.
    nonisolated static func exportableText(grid: Grid, selection: SelectionRange?) -> String {
        if let selection { return Selection.text(of: selection, in: grid) }
        // The whole document, the same range ⌘A builds: the scrollback
        // counts backwards from the live screen, so its first row is
        // `-scrollback.count`.
        let whole = SelectionRange(
            anchor: SelectionPoint(row: -grid.scrollback.count, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1))
        return Selection.text(of: whole, in: grid)
    }

    /// A name that says what the file is and when it was taken, so a folder
    /// of them is still readable a week later.
    static func exportFilename(hasSelection: Bool, date: Date = Date()) -> String {
        exportFilename(kind: hasSelection ? "Selection" : "History", date: date)
    }

    static func exportFilename(kind: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Corta \(kind) \(formatter.string(from: date)).txt"
    }
}

/// A mutable box for the `NSSavePanel` `exportText(_:)` is currently
/// presenting, so `withTaskCancellationHandler`'s `onCancel` — which can run
/// on any thread, concurrently with the operation still setting the box —
/// has something to dismiss. `@unchecked Sendable`: every read and write is
/// on the main actor (the panel itself is MainActor-affine), `onCancel` only
/// ever reads it from inside its own `Task { @MainActor in }` hop.
private final class PresentedPanelBox: @unchecked Sendable {
    var panel: NSSavePanel?
}
