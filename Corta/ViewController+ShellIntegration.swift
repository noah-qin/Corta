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

/// What OSC 133 marks make possible: command jumps and keyboard scrolling
/// (viewport moves in document rows), plus the OSC 52 clipboard drain,
/// which arrives through the same output path.
extension ViewController: NSMenuItemValidation {
    // MARK: - Scrolling from the keyboard

    @objc func scrollHistoryPageUp(_ sender: Any?) { scroll(.page(up: true)) }
    @objc func scrollHistoryPageDown(_ sender: Any?) { scroll(.page(up: false)) }
    @objc func scrollHistoryToTop(_ sender: Any?) { scroll(.toTop) }
    @objc func scrollHistoryToBottom(_ sender: Any?) { scroll(.toBottom) }

    // MARK: - Command to command

    @objc func jumpToPreviousCommand(_ sender: Any?) { jumpToCommand(backwards: true) }
    @objc func jumpToNextCommand(_ sender: Any?) { jumpToCommand(backwards: false) }

    /// Scrolls the nearest prompt in that direction to the top and makes it
    /// `effectiveCommand`. Walks `CommandRecordStore.records` by absolute row
    /// (`Grid.absoluteRow`), so scrollback and screen need no special case.
    private func jumpToCommand(backwards: Bool, failedOnly: Bool = false) {
        guard session != nil else { return }
        let grid = session.snapshot()
        let records = session.commandRecords.records.filter { !failedOnly || $0.didFail }
        guard !records.isEmpty else {
            // No marks: no shell integration, so don't jump anywhere.
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

    /// Scrolls `record`'s prompt to the top and selects it; shared with
    /// `focusCommand(id:)` so the two can't disagree.
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

    /// Lands on a command from a notification click (`TaskNotifier` tags it
    /// with the id). False if the bounded store has since dropped it.
    @discardableResult
    func focusCommand(id: Int) -> Bool {
        guard isOperable,
            let record = session.commandRecords.records.first(where: { $0.id == id })
        else { return false }
        land(on: record, in: session.snapshot())
        return true
    }

    // MARK: - Failed commands

    @objc func jumpToPreviousFailedCommand(_ sender: Any?) {
        jumpToCommand(backwards: true, failedOnly: true)
    }

    @objc func jumpToNextFailedCommand(_ sender: Any?) {
        jumpToCommand(backwards: false, failedOnly: true)
    }

    /// Greys the failed-command items when nothing failed.
    var hasFailedCommands: Bool {
        guard session != nil else { return false }
        return session.commandRecords.records.contains { $0.didFail }
    }

    // MARK: - The last command's output

    /// Copies `effectiveCommand`'s output, bounded by its marks, instead of a
    /// drag-while-scrolling selection. A toast reports either outcome.
    @objc func copyLastCommandOutput(_ sender: Any?) {
        guard isOperable else { return }
        guard let text = commandOutputText(for: effectiveCommand), !text.isEmpty else {
            // No marks means no integration; no completed command means a fresh
            // prompt. Say so either way.
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

    /// Opens the first `path:line[:column]` in `effectiveCommand`'s output
    /// with the same logic as ⌘-click (`ViewController+FileReferences.swift`).
    @objc func openFileReferenceInCommand(_ sender: Any?) {
        guard isOperable else { return }
        if let reference = fileReferenceInCommand(effectiveCommand) {
            open(reference)
            return
        }
        // Remote: open the managed local copy at the same line.
        if let remoteReference = remote.resolve(detectedReferenceInCommand(effectiveCommand)) {
            remote.open(remoteReference)
            return
        }
        terminalView?.showToast(L10n.text("toast.noFileReferenceInCommand"), kind: .warning)
    }

    @objc func searchCommandHistory(_ sender: Any?) {
        guard isOperable else { return }
        CommandHistoryController.shared.show(for: self)
    }

    /// A completed command's output as text.
    func commandOutputText(for record: CommandRecord?) -> String? {
        Self.commandOutputText(grid: session.snapshot(), record: record)
    }

    /// Pure, for `CommandOutputTests`. Without a `C` mark it starts one row
    /// past the prompt, which is a row too many for a two-line prompt.
    nonisolated static func commandOutputText(grid: Grid, record: CommandRecord?) -> String? {
        guard let range = commandOutputRange(grid: grid, record: record) else { return nil }
        let text = Selection.text(of: range, in: grid)
        return text.isEmpty ? nil : text
    }

    /// The document range of a completed command's output; nil while running
    /// or empty. `exportCommandOutput(_:)` needs the range itself.
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

    // MARK: - Command history: find/fill/run

    /// A historic command's text, read back from the grid (records keep only
    /// rows). Nil without a `B` mark on the prompt row, or once scrolled out;
    /// `CommandHistoryController` then greys Fill and Run.
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

    /// Writes `text` at the prompt only under `canChangeDirectorySafely`
    /// (integration present, nothing typed). Returns whether it wrote.
    @discardableResult
    func fillPrompt(with text: String) -> Bool {
        writeHistory(text, run: false)
    }

    /// `fillPrompt(with:)` then Return, as if the user typed it.
    @discardableResult
    func fillAndRunPrompt(with text: String) -> Bool {
        writeHistory(text, run: true)
    }

    private func writeHistory(_ text: String, run: Bool) -> Bool {
        guard canChangeDirectorySafely,
            var bytes = Paste.historyBytes(for: text, bracketedPasteEnabled: bracketedPasteEnabled())
        else { return false }
        if run { bytes.append(0x0D) }
        // Admit the closing paste marker and optional Return together, so
        // backpressure cannot execute a partially inserted command.
        switch session.write(chunks: Paste.chunked(bytes)) {
        case .accepted: return true
        case .backpressured, .stopped: return false
        }
    }

    /// The last completed command at or before the viewport top, pure.
    ///
    /// Filters `!isRunning`: every prompt opens a record at `OSC 133 ; A`, so
    /// when idle at the bottom the nearest record is the fresh empty one, not
    /// the command that just finished.
    nonisolated static func viewportCommand(
        in records: CommandRecordStore, grid: Grid, scrollOffset: Int
    ) -> CommandRecord? {
        let viewportTop = ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: scrollOffset)
        let bound = scrollOffset > 0 ? viewportTop + grid.rows : Int.max
        return records.records.last { !$0.isRunning && $0.promptRow <= bound }
    }

    /// The viewport command's output, for `CommandOutputTests`.
    nonisolated static func commandOutput(
        in grid: Grid, records: CommandRecordStore, scrollOffset: Int
    ) -> String? {
        commandOutputText(
            grid: grid, record: viewportCommand(in: records, grid: grid, scrollOffset: scrollOffset))
    }

    var hasShellIntegration: Bool {
        session?.hasShellIntegration == true
    }

    // MARK: - Command identity

    /// The target of copy, snapshot, export and open reference: the
    /// jump-selected command (cleared when the viewport scrolls away), else
    /// the viewport rule.
    var effectiveCommand: CommandRecord? {
        guard isOperable else { return nil }
        if let id = selectedCommandID,
            let record = session.commandRecords.records.first(where: { $0.id == id })
        {
            return record
        }
        return viewportCommand ?? latestCompletedCommand
    }

    /// The nearest prompt at or before the viewport top, so actions follow a
    /// scroll up.
    var viewportCommand: CommandRecord? {
        guard isOperable else { return nil }
        return Self.viewportCommand(
            in: session.commandRecords, grid: session.snapshot(), scrollOffset: scrollOffset)
    }

    /// The most recently completed command, regardless of scroll: a menu
    /// "last command" means the one that just finished.
    var latestCompletedCommand: CommandRecord? {
        guard isOperable else { return nil }
        return session.commandRecords.lastCompleted
    }

    /// Snapshots a still-running command's output so far — a build log at
    /// minute three is worth reading.
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

    /// Greys out items that need shell integration or a terminal, and the
    /// failed-command items without a failure: a disabled item says "not
    /// here" where a beep says nothing.
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
                || remote.resolve(detectedReferenceInCommand(effectiveCommand)) != nil
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
            // `shellDirectory` is nil exactly when there is no honest answer.
            return shellDirectory != nil && canChangeDirectorySafely
        // Not whether a root exists: finding one walks the path with a `stat`
        // per level, and the path is the child's — `/net/<host>/…` mounts on
        // first touch, and validation runs on the main thread each time a
        // menu opens. The action looks, off the main thread, and says so
        // when there is none.
        case #selector(changeDirectoryToProjectRoot(_:)):
            return hasKnownWorkingDirectory && canChangeDirectorySafely
        case #selector(openProjectRootInNewPane(_:)):
            return hasKnownWorkingDirectory
        default:
            // The actions the pane forwards are validated by their owner.
            return remote.validateMenuItem(menuItem)
        }
    }

    // MARK: - OSC 52

    /// Puts OSC 52 text on the pasteboard if the user allows it. Called per
    /// output batch from the damage pass; the policy lives here because the
    /// core has no pasteboard and no user.
    func drainClipboardRequests() {
        guard let text = session.takeClipboardCopy() else { return }
        guard ConfigurationStore.shared.configuration.allowClipboardWrite else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
