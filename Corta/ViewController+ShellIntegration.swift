import Cocoa
import CortaTerminal

/// M7.2, app side: the three things OSC 133 marks make possible.
///
/// Jumping between commands and the keyboard scroll actions are here because
/// both are viewport moves expressed in document rows; the clipboard drain is
/// here because OSC 52 arrives through the same output path and, like the
/// marks, is something the child told us rather than something we guessed.
extension ViewController: NSMenuItemValidation {
    // MARK: - Scrolling from the keyboard

    @objc func scrollHistoryPageUp(_ sender: Any?) { scroll(.page(up: true)) }
    @objc func scrollHistoryPageDown(_ sender: Any?) { scroll(.page(up: false)) }
    @objc func scrollHistoryToTop(_ sender: Any?) { scroll(.toTop) }
    @objc func scrollHistoryToBottom(_ sender: Any?) { scroll(.toBottom) }

    // MARK: - Command to command

    @objc func jumpToPreviousCommand(_ sender: Any?) { jumpToCommand(backwards: true) }
    @objc func jumpToNextCommand(_ sender: Any?) { jumpToCommand(backwards: false) }

    /// Scrolls so the nearest prompt in `backwards`'s direction sits at the
    /// top of the viewport, and makes that command `effectiveCommand` for
    /// every identity-based action (copy/snapshot/export/open-reference) —
    /// the single place navigation and "which command" agree (B07).
    ///
    /// Walks `CommandRecordStore.records` rather than `Grid.promptRows`/
    /// `failedPromptRows`: both used to do this same "nearest prompt at or
    /// before/after a row" search independently, and this is the one that
    /// also carries an id to select. Prompts are addressed by absolute row
    /// (`Grid.absoluteRow`), which is what makes this work across the
    /// scrollback boundary without a special case: the same arithmetic finds
    /// a prompt fifty thousand lines back and one still on screen.
    private func jumpToCommand(backwards: Bool, failedOnly: Bool = false) {
        guard session != nil else { return }
        let grid = session.snapshot()
        let records = session.commandRecords.records.filter { !failedOnly || $0.didFail }
        guard !records.isEmpty else {
            // No marks at all: the shell has no integration configured, and
            // pretending otherwise by jumping somewhere arbitrary would be
            // worse than doing nothing.
            NSSound.beep()
            return
        }
        let viewportTop = ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: scrollOffset)
        let target =
            backwards
            ? records.last { $0.promptRow < viewportTop }
            : records.first { $0.promptRow > viewportTop }
        guard let target else { return }
        land(on: target, in: grid)
    }

    /// Scrolls so `record`'s prompt sits at the top of the viewport and
    /// selects it — the landing half of `jumpToCommand`, shared with
    /// `focusCommand(id:)` (B07) so a notification's click and the keyboard
    /// jump can never disagree about what "landing on a command" means.
    private func land(on record: CommandRecord, in grid: Grid) {
        scrollOffset = min(
            max(
                0,
                ScrollbackCoordinates.offset(
                    forRow: record.promptRow, totalPushed: grid.scrollback.totalPushed)),
            grid.scrollback.count)
        selectedCommandID = record.id
        invalidateDisplay()
    }

    /// B07 — the notification-click half of the flow: `TaskNotifier` tags a
    /// finished command's notification with its id
    /// (`AppDelegate+Notifications.swift` reads it back), and this is where
    /// that id becomes a landed, selected command again. Returns whether the
    /// command was still there to find — `CommandRecordStore` is bounded
    /// (512 entries), so an old enough notification can outlive its record.
    @discardableResult
    func focusCommand(id: Int) -> Bool {
        guard isOperable,
            let record = session.commandRecords.records.first(where: { $0.id == id })
        else { return false }
        land(on: record, in: session.snapshot())
        return true
    }

    // MARK: - Failed commands (U14)

    @objc func jumpToPreviousFailedCommand(_ sender: Any?) {
        jumpToCommand(backwards: true, failedOnly: true)
    }

    @objc func jumpToNextFailedCommand(_ sender: Any?) {
        jumpToCommand(backwards: false, failedOnly: true)
    }

    /// Whether any command in this pane's history is known to have failed —
    /// the menu items are greyed out otherwise, rather than beeping at a
    /// person who has had a good day.
    var hasFailedCommands: Bool {
        guard session != nil else { return false }
        return session.commandRecords.records.contains { $0.didFail }
    }

    // MARK: - The last command's output (U14)

    /// Copies `effectiveCommand`'s output to the clipboard.
    ///
    /// The thing this replaces is selecting it by hand: a long build log's
    /// output starts several screens up, and dragging to it means scrolling
    /// while dragging, which is the gesture U19 had to make work at all. The
    /// marks already say where the command started and where the next prompt
    /// is; the range between them is the answer, and nothing has to be
    /// guessed from the text.
    ///
    /// Reported by toast either way, because both outcomes are invisible
    /// otherwise: a clipboard that changed silently, or one that did not.
    @objc func copyLastCommandOutput(_ sender: Any?) {
        guard isOperable else { return }
        guard let text = commandOutputText(for: effectiveCommand), !text.isEmpty else {
            // No marks at all is a shell with no integration configured;
            // marks but no completed command is a fresh prompt. Neither is an
            // error, and neither is something to do silently.
            terminalView?.showToast(
                L10n.text(
                    hasShellIntegration ? "toast.noCommandOutput" : "toast.noShellIntegration"),
                kind: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        terminalView?.showToast(L10n.text("toast.copiedCommandOutput"))
    }

    /// B07 — opens the first `path:line[:column]` reference found in
    /// `effectiveCommand`'s output, without hunting through a scrollback
    /// full of it by eye first. `fileReferenceInCommand`
    /// (`ViewController+FileReferences.swift`) finds the reference; `open`
    /// there is the same file-opening logic ⌘-click already uses — this
    /// only supplies which reference, tied to a command instead of a mouse
    /// position.
    @objc func openFileReferenceInCommand(_ sender: Any?) {
        guard isOperable else { return }
        guard let reference = fileReferenceInCommand(effectiveCommand) else {
            terminalView?.showToast(L10n.text("toast.noFileReferenceInCommand"), kind: .warning)
            return
        }
        open(reference)
    }

    /// B08 — opens `CommandHistoryController`, the search/find/fill/run
    /// surface for this pane's command records.
    @objc func searchCommandHistory(_ sender: Any?) {
        guard isOperable else { return }
        CommandHistoryController.shared.show(for: self)
    }

    /// A completed command's output as text, using the same document-row
    /// arithmetic every identity-based action shares — the one place a
    /// `CommandRecord`'s rows become a `Selection` range.
    func commandOutputText(for record: CommandRecord?) -> String? {
        Self.commandOutputText(grid: session.snapshot(), record: record)
    }

    /// Static and pure so the range arithmetic is testable without a pane —
    /// `CommandOutputTests` drives this directly against a bare `Terminal`.
    ///
    /// Falls back to one row past the prompt when the shell's integration
    /// emits `A` and `D` but not `C` — right for a one-line prompt with the
    /// command typed on it, one row too much for a two-line prompt or a
    /// continued command, same trade `Grid+Marks.swift`'s row-based version
    /// of this used to make before `CommandRecord` replaced it (B07).
    nonisolated static func commandOutputText(grid: Grid, record: CommandRecord?) -> String? {
        guard let range = commandOutputRange(grid: grid, record: record) else { return nil }
        let text = Selection.text(of: range, in: grid)
        return text.isEmpty ? nil : text
    }

    /// The document-row `SelectionRange` a completed `record`'s output
    /// covers, or `nil` while it is still running or printed nothing —
    /// shared by `commandOutputText(grid:record:)` and
    /// `ViewController.exportCommandOutput(_:)`, which needs the range
    /// itself rather than materialised text.
    nonisolated static func commandOutputRange(grid: Grid, record: CommandRecord?) -> SelectionRange? {
        guard let record, let end = record.endRow else { return nil }
        let start = record.outputStartRow ?? record.promptRow + 1
        guard start < end else { return nil }
        let base = grid.scrollback.totalPushed
        return SelectionRange(
            anchor: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(start, totalPushed: base), column: 0),
            head: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(end - 1, totalPushed: base),
                column: grid.columns - 1))
    }

    // MARK: - Command history: find/fill/run (B08)

    /// The literal text of a historic command, read back from the grid
    /// rather than stored anywhere — `CommandRecord` never captured it, only
    /// row markers (B07's doc comment on why a row is not enough applies
    /// here too: the text itself is even less worth duplicating). `nil`
    /// covers every honest reason it cannot be recovered: no `B` mark ever
    /// landed on the prompt's own row (`record.promptEndColumn`), or the row
    /// has since scrolled out of the bounded scrollback — `CommandHistory
    /// Controller` greys out Fill/Run rather than guessing either way.
    func commandLineText(for record: CommandRecord?) -> String? {
        Self.commandLineText(grid: session.snapshot(), record: record)
    }

    nonisolated static func commandLineText(grid: Grid, record: CommandRecord?) -> String? {
        guard let record, let column = record.promptEndColumn else { return nil }
        guard let end = record.outputStartRow ?? record.endRow, end > record.promptRow
        else { return nil }
        let base = grid.scrollback.totalPushed
        let range = SelectionRange(
            anchor: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(record.promptRow, totalPushed: base),
                column: column),
            head: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(end - 1, totalPushed: base),
                column: grid.columns - 1))
        let text = Selection.text(of: range, in: grid).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Writes `text` at the current prompt, only when `canChangeDirectorySafely`
    /// holds — the same "pane exists, shell integration present, nothing
    /// already typed" gate `changeDirectory(to:)` already enforces, reused
    /// as-is: filling a historic command at a busy or dirty prompt is exactly
    /// as unsafe as `cd`-ing one would be. Returns whether it wrote.
    @discardableResult
    func fillPrompt(with text: String) -> Bool {
        guard canChangeDirectorySafely else { return false }
        session.write(Array(text.utf8))
        return true
    }

    /// `fillPrompt(with:)`, then Return — equivalent to the user pasting the
    /// line and pressing Return themselves, not a new execution path.
    @discardableResult
    func fillAndRunPrompt(with text: String) -> Bool {
        guard fillPrompt(with: text) else { return false }
        session.write(Array("\r".utf8))
        return true
    }

    /// The last *completed* command at or before the top of the viewport —
    /// same rule, static and pure, that the instance `viewportCommand`
    /// applies with a live pane's `session`/`scrollOffset`.
    ///
    /// Filters to `!isRunning` rather than using `CommandRecordStore
    /// .record(before:)` as-is: every prompt, including one just opened
    /// with nothing typed on it yet, starts its own `CommandRecord` the
    /// moment `OSC 133 ; A` draws it (`Performer+ShellIntegration.swift`) —
    /// so at the ordinary "scrolled to the bottom, idle" bound (`.max`), the
    /// *nearest* record is always that fresh, running, empty one, never the
    /// command that actually just finished. The old row-based
    /// `Grid.commandOutputRows(before:)` this replaced sidestepped the same
    /// trap by construction, always keying off a *pair* of consecutive
    /// prompts — this reaches the identical answer by requiring the record
    /// itself to be finished.
    nonisolated static func viewportCommand(
        in records: CommandRecordStore, grid: Grid, scrollOffset: Int
    ) -> CommandRecord? {
        let viewportTop = ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: scrollOffset)
        let bound = scrollOffset > 0 ? viewportTop + grid.rows : Int.max
        return records.records.last { !$0.isRunning && $0.promptRow <= bound }
    }

    /// The output of the command the viewport is looking at, as text — the
    /// pure composition of `viewportCommand(in:grid:scrollOffset:)` and
    /// `commandOutputText(grid:record:)` `CommandOutputTests` exercises.
    nonisolated static func commandOutput(
        in grid: Grid, records: CommandRecordStore, scrollOffset: Int
    ) -> String? {
        commandOutputText(
            grid: grid, record: viewportCommand(in: records, grid: grid, scrollOffset: scrollOffset))
    }

    /// Whether the pane can currently jump — used to grey the menu items out
    /// on a shell with no integration rather than leaving them live and
    /// silent.
    var hasShellIntegration: Bool {
        session?.hasShellIntegration == true
    }

    // MARK: - Command identity (B07)

    /// The command every identity-based action (copy, snapshot, export, open
    /// file reference) targets: whatever jump navigation last selected —
    /// `selectedCommandID` is cleared the moment the viewport scrolls away
    /// from it (`ViewController.scrollOffset`'s `didSet`), so a stale
    /// selection never survives to be returned here — else the same
    /// "viewport, falling back to latest completed" rule those actions used
    /// to each reimplement separately.
    var effectiveCommand: CommandRecord? {
        guard isOperable else { return nil }
        if let id = selectedCommandID,
            let record = session.commandRecords.records.first(where: { $0.id == id })
        {
            return record
        }
        return viewportCommand ?? latestCompletedCommand
    }

    /// The command the viewport is looking at — the nearest prompt at or
    /// before the top of the viewport, so scrolling up to read an old
    /// command's output means identity-based actions follow it there.
    var viewportCommand: CommandRecord? {
        guard isOperable else { return nil }
        return Self.viewportCommand(
            in: session.commandRecords, grid: session.snapshot(), scrollOffset: scrollOffset)
    }

    /// The most recently *completed* command, regardless of where the
    /// viewport is scrolled — distinct from `viewportCommand` on purpose
    /// (B07): scrolled up to read an old failure, "copy the last command's
    /// output" from a menu with no row context should still mean the one
    /// that just finished, not the one currently in view.
    var latestCompletedCommand: CommandRecord? {
        guard isOperable else { return nil }
        return session.commandRecords.lastCompleted
    }

    /// B07 — takes a marked, timestamped snapshot of a still-running
    /// command's output so far. `copyLastCommandOutput` only ever finds a
    /// *completed* command (`commandOutputRows` requires a following
    /// prompt); this is the answer for "it's still building, but I want
    /// what it's printed so far" — a build log at minute three is still
    /// worth reading, and waiting for `OSC 133 ; D` to read it would be a
    /// terminal that makes the user wait on itself.
    @objc func snapshotRunningCommandOutput(_ sender: Any?) {
        guard isOperable else { return }
        let grid = session.snapshot()
        guard let record = session.commandRecords.last, record.isRunning else {
            terminalView?.showToast(L10n.text("toast.noCommandRunning"), kind: .warning)
            return
        }
        let startRow = record.outputStartRow ?? record.promptRow + 1
        let endRow = grid.absoluteRow(ofScreenRow: grid.cursor.row)
        guard startRow < endRow else {
            terminalView?.showToast(L10n.text("toast.noCommandOutput"), kind: .warning)
            return
        }
        let base = grid.scrollback.totalPushed
        let range = SelectionRange(
            anchor: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(startRow, totalPushed: base), column: 0),
            head: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(endRow - 1, totalPushed: base),
                column: grid.columns - 1))
        let text = Selection.text(of: range, in: grid)
        guard !text.isEmpty else {
            terminalView?.showToast(L10n.text("toast.noCommandOutput"), kind: .warning)
            return
        }
        let stamped = "\(L10n.format("snapshot.header", Self.snapshotTimestampFormatter.string(from: Date())))\n\(text)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(stamped, forType: .string)
        terminalView?.showToast(L10n.text("toast.snapshotCopied"))
    }

    private static let snapshotTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - Menu validation

    /// Greys out the items that depend on shell integration, or on a
    /// terminal existing at all, rather than leaving them live and silent.
    ///
    /// A command jump with no marks used to beep, which says "not now"
    /// without saying why; a disabled item with a shell-integration section
    /// in `CONFIGURATION.md` behind it says which. The failed-command items
    /// go further and require a failure to actually exist — an enabled "Next
    /// Failed Command" in a session where nothing failed is an invitation to
    /// press it and learn nothing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(jumpToPreviousCommand(_:)), #selector(jumpToNextCommand(_:)):
            return hasShellIntegration
        case #selector(jumpToPreviousFailedCommand(_:)),
            #selector(jumpToNextFailedCommand(_:)):
            return hasShellIntegration && hasFailedCommands
        case #selector(copyLastCommandOutput(_:)), #selector(exportCommandOutput(_:)):
            return commandOutputText(for: effectiveCommand) != nil
        case #selector(snapshotRunningCommandOutput(_:)):
            guard isOperable else { return false }
            return session.commandRecords.last?.isRunning == true
        case #selector(openFileReferenceInCommand(_:)):
            guard isOperable else { return false }
            return fileReferenceInCommand(effectiveCommand) != nil
        case #selector(searchCommandHistory(_:)):
            return isOperable
        case #selector(clearScreen(_:)), #selector(clearHistory(_:)),
            #selector(resetTerminal(_:)):
            return validateTerminalStateItem(menuItem)
        case #selector(exportText(_:)):
            return isOperable
        case #selector(revealWorkingDirectoryInFinder(_:)), #selector(copyWorkingDirectoryPath(_:)),
            #selector(openParentDirectoryInNewPane(_:)):
            return hasKnownWorkingDirectory
        case #selector(changeDirectoryToParent(_:)):
            return hasKnownWorkingDirectory && canChangeDirectorySafely
        case #selector(changeDirectoryToProjectRoot(_:)):
            return hasKnownWorkingDirectory && canChangeDirectorySafely
                && session.workingDirectory.flatMap { DirectoryHistory.projectRoot(for: $0) } != nil
        case #selector(openProjectRootInNewPane(_:)):
            return hasKnownWorkingDirectory
                && session.workingDirectory.flatMap { DirectoryHistory.projectRoot(for: $0) } != nil
        default:
            return true
        }
    }

    // MARK: - OSC 52 (M7.11)

    /// Puts text the child asked to copy onto the pasteboard, if the user
    /// allows it.
    ///
    /// Called once per output batch from the render loop's damage pass, which
    /// is where every other "the child told us something" hand-off already
    /// happens. The setting is checked *here* rather than in the core: the
    /// core has no pasteboard and no user, and a policy question belongs with
    /// the layer that can ask one.
    func drainClipboardRequests() {
        guard let text = session.takeClipboardCopy() else { return }
        guard ConfigurationStore.shared.configuration.allowClipboardWrite else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
