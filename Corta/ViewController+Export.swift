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
    /// thread rather than stalling the panel's own appearance and every
    /// other interaction behind it. It starts immediately, in parallel with
    /// the save panel the user is about to spend a few seconds navigating,
    /// so the common case pays the cost concurrently rather than serially;
    /// only the write and the resulting toast wait for the panel's answer.
    /// `largeTextTask` cancels a superseded export (a second ⌘⇧S before the
    /// first panel closed) and is cancelled itself from `teardown()`, so a
    /// closed pane's build does not keep running for a write that can never
    /// land.
    @objc func exportText(_ sender: Any?) {
        guard isOperable, let window = view.window, session != nil else { return }
        let grid = session.snapshot()
        let hasSelection = selection != nil
        let range = selection.map { selectionRange(for: $0, in: grid) }

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
            // `async let`'s structured-concurrency guarantee cuts both ways:
            // cancelling this task (a superseded export, or `teardown()`)
            // stops `built`'s result from ever being applied below, but if
            // the scope returns early (no `url`) before `await built`, the
            // implicit await built into leaving an `async let` scope still
            // waits for the build to finish first — Swift never leaves an
            // orphaned structured child behind. That wait is invisible to
            // the user (this whole task is already off the main actor), but
            // it does mean "cancelled" only ever means "the result is
            // discarded," never "the build stopped early" — the same
            // limit `largeTextTask`'s own doc comment now states plainly.
            async let built = Self.exportableText(grid: grid, selection: range)

            let url: URL? = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    // Unstructured, so cancelling the outer `largeTextTask`
                    // does not cancel this presentation task by itself — a
                    // pane torn down (or a superseded export) between that
                    // cancellation and this hop running would otherwise
                    // still show a save panel for a pane that is already
                    // gone. Checked here, not just at the final apply.
                    guard let self, !self.didTeardown,
                        self.largeTextTaskGeneration == generation
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = Self.exportFilename(hasSelection: hasSelection)
                    panel.canCreateDirectories = true
                    panel.isExtensionHidden = false
                    panel.message = L10n.text(
                        hasSelection ? "export.message.selection" : "export.message.history")
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                }
            }

            enum Outcome {
                case cancelledOrDismissed
                case empty
                case wrote
                case failed(Error)
            }
            let outcome: Outcome
            if Task.isCancelled {
                outcome = .cancelledOrDismissed
            } else if let url {
                let text = await built
                if Task.isCancelled {
                    outcome = .cancelledOrDismissed
                } else if text.isEmpty {
                    outcome = .empty
                } else {
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
                }
            } else {
                outcome = .cancelledOrDismissed
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let kind = hasSelection ? "Selection" : "History"
        return "Corta \(kind) \(formatter.string(from: date)).txt"
    }
}
