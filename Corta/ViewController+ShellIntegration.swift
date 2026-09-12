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
    /// top of the viewport.
    ///
    /// Prompts are addressed by absolute row (`Grid.absoluteRow`), which is
    /// what makes this work across the scrollback boundary without a special
    /// case: the same arithmetic finds a prompt fifty thousand lines back and
    /// one still on screen.
    private func jumpToCommand(backwards: Bool, failedOnly: Bool = false) {
        guard session != nil else { return }
        let grid = session.snapshot()
        let prompts = failedOnly ? grid.failedPromptRows : grid.promptRows
        guard !prompts.isEmpty else {
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
            ? prompts.last { $0 < viewportTop }
            : prompts.first { $0 > viewportTop }
        guard let target else { return }
        scrollOffset = min(
            max(0, ScrollbackCoordinates.offset(forRow: target, totalPushed: grid.scrollback.totalPushed)),
            grid.scrollback.count)
        invalidateDisplay()
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
        return !session.snapshot().failedPromptRows.isEmpty
    }

    // MARK: - The last command's output (U14)

    /// Copies the output of the last completed command to the clipboard.
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
        let grid = session.snapshot()
        guard let text = Self.commandOutput(in: grid, scrollOffset: scrollOffset),
            !text.isEmpty
        else {
            // No marks at all is a shell with no integration configured;
            // marks but no completed command is a fresh prompt. Neither is an
            // error, and neither is something to do silently.
            terminalView?.showToast(
                L10n.text(
                    grid.promptRows.isEmpty
                        ? "toast.noShellIntegration" : "toast.noCommandOutput"),
                kind: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        terminalView?.showToast(L10n.text("toast.copiedCommandOutput"))
    }

    /// The output of the command the viewport is looking at, as text.
    ///
    /// Scrolled to the bottom this is the last command's, which is the
    /// ordinary case. Scrolled up it is the command whose output the user is
    /// *reading* — the one whose prompt is nearest above the top of the
    /// viewport — because a command has to have scrolled off the bottom
    /// before anyone wants to scroll back to it, and taking the last one
    /// there would copy something the user cannot see (U14).
    ///
    /// Static and pure so the row arithmetic is testable without a pane.
    /// The rows the command in view wrote, without materialising their text.
    ///
    /// `validateMenuItem` needs to know only *whether* there is anything to
    /// copy, and AppKit asks it every time the menu is opened or a key
    /// equivalent is matched. Building the string to answer that walked and
    /// joined the whole output on the main thread each time.
    static func commandOutputRows(in grid: Grid, scrollOffset: Int) -> Range<Int>? {
        let viewportTop = ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: scrollOffset)
        let bound = scrollOffset > 0 ? viewportTop + grid.rows : Int.max
        return grid.commandOutputRows(before: bound)
    }

    static func commandOutput(in grid: Grid, scrollOffset: Int) -> String? {
        guard let rows = commandOutputRows(in: grid, scrollOffset: scrollOffset) else {
            return nil
        }
        // Absolute rows to the document rows selection speaks in.
        let base = grid.scrollback.totalPushed
        let range = SelectionRange(
            anchor: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(rows.lowerBound, totalPushed: base), column: 0),
            head: SelectionPoint(
                row: ScrollbackCoordinates.relativeRow(rows.upperBound - 1, totalPushed: base),
                column: grid.columns - 1))
        let text = Selection.text(of: range, in: grid)
        return text.isEmpty ? nil : text
    }

    /// Whether the pane can currently jump — used to grey the menu items out
    /// on a shell with no integration rather than leaving them live and
    /// silent.
    var hasShellIntegration: Bool {
        session?.hasShellIntegration == true
    }

    // MARK: - Command identity (B07)

    /// The command the viewport is looking at — see `commandOutput(in
    /// scrollOffset:)`'s doc comment for the same "nearest prompt at or
    /// before the top of the viewport" rule, expressed here as an identity
    /// rather than a row range.
    var viewportCommand: CommandRecord? {
        guard isOperable else { return nil }
        let grid = session.snapshot()
        let viewportTop = ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: scrollOffset)
        let bound = scrollOffset > 0 ? viewportTop + grid.rows : Int.max
        return session.commandRecords.record(before: bound)
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
        case #selector(copyLastCommandOutput(_:)):
            guard isOperable else { return false }
            return Self.commandOutputRows(in: session.snapshot(), scrollOffset: scrollOffset)
                != nil
        case #selector(snapshotRunningCommandOutput(_:)):
            guard isOperable else { return false }
            return session.commandRecords.last?.isRunning == true
        case #selector(clearScreen(_:)), #selector(clearHistory(_:)),
            #selector(resetTerminal(_:)):
            return validateTerminalStateItem(menuItem)
        case #selector(exportText(_:)):
            return isOperable
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
