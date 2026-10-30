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
import OSLog

/// Three identical prompt-line samples, 100 ms apart, before a fill or a skip.
/// A right prompt or a transient redraw must not discard the pane on the first look.
nonisolated struct ConversationPromptReadiness: Equatable, Sendable {
    static let stableSamples = 3
    private(set) var samples = 0
    private var signature: [UInt32] = []

    enum Decision: Equatable, Sendable { case wait, fill, skip }

    mutating func observe(signature: [UInt32], isEmpty: Bool) -> Decision {
        if signature == self.signature {
            samples += 1
        } else {
            self.signature = signature
            samples = 1
        }
        guard samples >= Self.stableSamples else { return .wait }
        return isEmpty ? .fill : .skip
    }
}

extension Notification.Name {
    /// Kind, UUID, source or process identity of one Space session changed.
    /// `object` is the session's `UUID`. Nothing in the note is a transcript.
    static let spaceConversationIdentityDidChange = Notification.Name(
        "dev.noahqin.Corta.spaceConversationIdentityDidChange")
}

/// What #437 binds on. Equal samples do not notify.
nonisolated struct ConversationIdentity: Equatable, Sendable {
    var conversation: LocalConversation?
    var processes: [ConversationProcess]

    init(conversation: LocalConversation?, processes: [ConversationProcess]) {
        self.conversation = conversation
        self.processes = processes
    }
}

extension CortaSpaceController {
    private static let conversationLog = Logger(subsystem: "dev.noahqin.Corta", category: "space")

    /// One bounded batch at a time, also while Space is hidden. The only
    /// retained result is kind + optional UUID + source; an exited process leaves the last one.
    func startConversationMonitor() {
        guard conversationMonitor == nil else { return }
        conversationMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.sampleConversations()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func sampleConversations() async {
        let candidates = projects.flatMap(\.sessions).compactMap { item -> (UUID, TerminalSession)? in
            guard item.record.ssh == nil, let pane = item.pane,
                  case .local = pane.remote.state, let terminal = pane.session else { return nil }
            return (item.id, terminal)
        }
        let updates = await Task.detached(priority: .utility) {
            candidates.map { ($0.0, $0.1.pty.conversationSample) }
        }.value
        guard !Task.isCancelled else { return }
        for (id, sample) in updates {
            guard let sample, let (_, item) = session(withID: id),
                  let original = candidates.first(where: { $0.0 == id })?.1,
                  item.pane?.session === original, item.record.ssh == nil,
                  case .local = item.pane?.remote.state else { continue }
            applyConversationSample(sample, to: item)
        }
    }

    func applyConversationSample(_ sample: ConversationSample, to item: SpaceSession) {
        let before = ConversationIdentity(
            conversation: item.record.conversation, processes: item.conversationObservation?.processes ?? [])
        guard case .observed(let observation) = sample else {
            item.conversationObservation = nil
            item.conversationNeedsNotice = false
            item.conversationFilledCommand = nil
            if item.record.conversation != nil {
                item.record.conversation = nil
                scheduleSave()
            }
            noteIdentityChange(from: before, on: item)
            return
        }
        let conversation = observation.retainingIdentity(
            item.record.conversation, previousProcesses: item.conversationObservation?.processes)
        let settled = observation.settled()
        if observation.sessionChanged || item.conversationObservation != settled {
            let result = observation.sessionChanged
                ? ConversationObservation.Reason.sessionChanged.rawValue
                : (observation.reason?.rawValue ?? "success")
            let kind = conversation.kind.rawValue
            let source = conversation.source.rawValue
            Self.conversationLog.info("""
                conversation kind=\(kind, privacy: .public) \
                source=\(source, privacy: .public) result=\(result, privacy: .public)
                """)
        }
        item.conversationObservation = settled
        if item.record.conversation != conversation {
            item.record.conversation = conversation
            scheduleSave()
        }
        noteIdentityChange(from: before, on: item)
    }

    private func noteIdentityChange(from before: ConversationIdentity, on item: SpaceSession) {
        let after = ConversationIdentity(
            conversation: item.record.conversation, processes: item.conversationObservation?.processes ?? [])
        guard before != after else { return }
        NotificationCenter.default.post(name: .spaceConversationIdentityDidChange, object: item.id)
    }

    nonisolated static func conversationNoticeKey(for conversations: [LocalConversation]) -> String {
        if conversations.count > 1 { return "space.conversation.filledMany" }
        return conversations.first?.id == nil ? "space.conversation.pickerFilled" : "space.conversation.filled"
    }

    private struct PendingConversation {
        let item: SpaceSession
        let terminal: TerminalSession
        let inputRevision: UInt64
        var readiness = ConversationPromptReadiness()
        var fillAttempts = 0
    }

    /// Wait for each new shell's first integrated prompt, not a fixed startup
    /// delay. The prompt line must sit still for a few samples — a right prompt
    /// redraws after the cursor — and a failed write is tried again, not counted.
    func prepareConversations(in project: SpaceProject) {
        let candidates = project.sessions.compactMap { item -> PendingConversation? in
            guard item.record.ssh == nil, item.record.conversation != nil,
                  let pane = item.pane, let terminal = pane.session else { return nil }
            return PendingConversation(item: item, terminal: terminal,
                                       inputRevision: pane.terminalView?.userInputRevision ?? 0)
        }
        guard !candidates.isEmpty else { return }
        project.conversationPreparation = Task { [weak self, weak project] in
            let deadline = SuspendingClock.now.advanced(by: .seconds(10))
            var pending = candidates
            var filled: [SpaceSession] = []
            while !pending.isEmpty, SuspendingClock.now < deadline {
                guard !Task.isCancelled, let self, let project, self.projects.contains(project) else { return }
                var remaining: [PendingConversation] = []
                for var candidate in pending where self.keepWaiting(&candidate, in: project, filled: &filled) {
                    remaining.append(candidate)
                }
                pending = remaining
                if !pending.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard !Task.isCancelled, let self, let project, self.isActive, self.selectedProject === project,
                  !filled.isEmpty else { return }
            let key = Self.conversationNoticeKey(for: filled.compactMap { $0.record.conversation })
            self.content.showNote(L10n.text(key))
        }
    }

    func canFillConversation(_ item: SpaceSession) -> Bool {
        guard item.record.ssh == nil, item.record.conversation != nil, let pane = item.pane,
              case .local = pane.remote.state else { return false }
        guard pane.commands.canChangeDirectorySafely, let terminal = pane.session,
              let end = terminal.promptEndPosition else { return false }
        return Self.isEmptyConversationPrompt(in: terminal.snapshot(), row: end.row, column: end.column)
    }

    /// Keeps a pane until its prompt line has been stable, then fills or skips.
    /// Typing or a shell that exits abandons immediately. Returns whether to keep waiting.
    private func keepWaiting(
        _ candidate: inout PendingConversation, in project: SpaceProject, filled: inout [SpaceSession]
    ) -> Bool {
        let item = candidate.item
        guard project.sessions.contains(item), let pane = item.pane, let terminal = pane.session,
              terminal === candidate.terminal,
              pane.terminalView?.userInputRevision == candidate.inputRevision else { return false }
        guard let end = terminal.promptEndPosition else { return terminal.pty.exitStatus == nil }
        let grid = terminal.snapshot()
        guard let signature = Self.conversationPromptSignature(in: grid, row: end.row, column: end.column)
        else { return true }
        let empty = Self.isEmptyConversationPrompt(in: grid, row: end.row, column: end.column)
        switch candidate.readiness.observe(signature: signature, isEmpty: empty) {
        case .wait:
            return true
        case .skip:
            return false
        case .fill:
            guard fillConversation(item) else {
                candidate.fillAttempts += 1
                return candidate.fillAttempts < ConversationPromptReadiness.stableSamples
            }
            filled.append(item)
            item.conversationNeedsNotice = !(isActive && selectedProject === project && project.shown.contains(item))
            return false
        }
    }

    /// Cells from the cursor through the logical prompt line. A redraw changes this.
    nonisolated static func conversationPromptSignature(in grid: Grid, row: Int, column: Int) -> [UInt32]? {
        guard let screenRow = grid.screenRow(ofAbsoluteRow: row),
              (0..<grid.columns).contains(column) else { return nil }
        var scalars: [UInt32] = []
        for index in screenRow..<grid.rows {
            if index > screenRow, !grid.line(index).wrapped { break }
            if index > screenRow { scalars.append(0x0A) }
            let start = index == screenRow ? column : 0
            for cell in start..<grid.columns { scalars.append(grid[index, cell].scalar) }
        }
        return scalars
    }

    /// A cursor at the start alone is insufficient: Home can leave typed
    /// text after it. A right prompt is the trailing run, flush to the line
    /// and separated from the cursor by a space; that run is not user text.
    /// A wrapped continuation that holds anything is user text.
    nonisolated static func isEmptyConversationPrompt(in grid: Grid, row: Int, column: Int) -> Bool {
        guard !grid.isAlternateScreenActive, let screenRow = grid.screenRow(ofAbsoluteRow: row),
              (0..<grid.columns).contains(column) else { return false }
        for index in (screenRow + 1)..<grid.rows {
            guard grid.line(index).wrapped else { break }
            for cell in 0..<grid.columns where !isConversationPadding(grid[index, cell]) { return false }
        }
        return inputBeforeRightPromptIsEmpty(in: grid, row: screenRow, column: column)
    }

    /// Blank, or the spacer half of a wide glyph. A wide spacer is part of the glyph before it.
    private nonisolated static func isConversationPadding(_ cell: Cell) -> Bool {
        if cell.attributes.contains(.wideSpacer) { return false }
        return cell.scalar == 0 || cell.scalar == 32
    }

    private nonisolated static func inputBeforeRightPromptIsEmpty(in grid: Grid, row: Int, column: Int) -> Bool {
        var end = grid.columns - 1
        while end >= column, isConversationPadding(grid[row, end]) { end -= 1 }
        if end < column { return true }
        var start = end
        while start > column, !isConversationPadding(grid[row, start - 1]) { start -= 1 }
        // Text that begins at the cursor has no gap, so it is the input, not a right prompt.
        if start == column { return false }
        for cell in column..<start where !isConversationPadding(grid[row, cell]) { return false }
        return true
    }

    @discardableResult
    func fillConversation(_ item: SpaceSession) -> Bool {
        guard canFillConversation(item), let conversation = item.record.conversation else { return false }
        guard item.pane?.shell.fillPrompt(with: conversation.command) == true else { return false }
        item.conversationFilledCommand = conversation.command
        item.conversationFilledPrompt = item.pane?.session?.promptEndPosition
        return true
    }

    func refillConversation(_ item: SpaceSession) {
        guard fillConversation(item) else { return }
        content.showNote(L10n.text(Self.conversationNoticeKey(for: [item.record.conversation].compactMap { $0 })))
    }

    /// Compare exact ASCII input cells, including spaces, rather than copied
    /// selection text (which trims trailing blanks). Right prompts are excluded.
    private nonisolated static func hasFilledConversationPrompt(
        in grid: Grid, row: Int, column: Int, command: String
    ) -> Bool {
        guard !grid.isAlternateScreenActive, !grid.pendingWrap,
              let row = grid.screenRow(ofAbsoluteRow: row) else { return false }
        let start = row * grid.columns + column
        let end = grid.cursor.row * grid.columns + grid.cursor.column
        let expected = Array(command.unicodeScalars.map(\.value))
        guard end - start == expected.count else { return false }
        for (offset, scalar) in expected.enumerated() {
            let index = start + offset
            let line = index / grid.columns
            guard line == row || grid.line(line).wrapped, grid[line, index % grid.columns].scalar == scalar
            else { return false }
        }
        return Self.isEmptyConversationPrompt(in: grid, row: grid.absoluteRow(ofScreenRow: grid.cursor.row),
                                             column: grid.cursor.column)
    }

    func showConversationNoticeIfNeeded() {
        guard let project = selectedProject else { return }
        for item in project.shown where item.conversationNeedsNotice {
            item.conversationNeedsNotice = false
            guard let command = item.conversationFilledCommand, let pane = item.pane,
                  let terminal = pane.session, !terminal.isCommandRunning,
                  let end = terminal.promptEndPosition,
                  end.row == item.conversationFilledPrompt?.row,
                  end.column == item.conversationFilledPrompt?.column else { continue }
            guard Self.hasFilledConversationPrompt(in: terminal.snapshot(), row: end.row,
                                                   column: end.column, command: command) else { continue }
            content.showNote(L10n.text("space.conversation.continue"))
        }
    }
}
