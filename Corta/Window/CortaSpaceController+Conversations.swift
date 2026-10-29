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

extension CortaSpaceController {
    /// One bounded batch at a time, also while Space is hidden. The only
    /// retained result is kind + UUID; an exited process leaves the last one.
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
            candidates.map { ($0.0, $0.1.localConversation) }
        }.value
        guard !Task.isCancelled else { return }
        for (id, conversation) in updates {
            guard let conversation, let (_, item) = session(withID: id),
                  let original = candidates.first(where: { $0.0 == id })?.1,
                  item.pane?.session === original, item.record.ssh == nil,
                  case .local = item.pane?.remote.state,
                  item.record.conversation != conversation else { continue }
            item.record.conversation = conversation
            scheduleSave()
        }
    }

    private struct PendingConversation {
        let item: SpaceSession
        let terminal: TerminalSession
        let inputRevision: UInt64
    }

    /// Wait for each new shell's first integrated prompt, not a fixed startup
    /// delay. Each pane gets one attempt; failed writes never count as filled.
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
                pending.removeAll { pending in
                    let item = pending.item
                    guard project.sessions.contains(item), let pane = item.pane, let terminal = pane.session,
                          terminal === pending.terminal,
                          pane.terminalView?.userInputRevision == pending.inputRevision else {
                        return true
                    }
                    guard terminal.promptEndPosition != nil else { return terminal.pty.exitStatus != nil }
                    if self.fillConversation(item) {
                        filled.append(item)
                        item.conversationNeedsNotice = !(self.isActive && self.selectedProject === project
                            && project.shown.contains(item))
                    }
                    return true
                }
                if !pending.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard !Task.isCancelled, let self, let project, self.isActive, self.selectedProject === project,
                  !filled.isEmpty else { return }
            let key = filled.count == 1 ? "space.conversation.filled" : "space.conversation.filledMany"
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

    /// A cursor at the start alone is insufficient: Home can leave typed
    /// text after it. If right-prompt text makes emptiness uncertain, skip.
    nonisolated static func isEmptyConversationPrompt(in grid: Grid, row: Int, column: Int) -> Bool {
        guard !grid.isAlternateScreenActive, let screenRow = grid.screenRow(ofAbsoluteRow: row),
              (0..<grid.columns).contains(column) else { return false }
        for index in screenRow..<grid.rows {
            if index > screenRow, !grid.line(index).wrapped { break }
            let start = index == screenRow ? column : 0
            for cell in start..<grid.columns where grid[index, cell].scalar != 0 && grid[index, cell].scalar != 32 {
                return false
            }
        }
        return true
    }

    @discardableResult
    func fillConversation(_ item: SpaceSession) -> Bool {
        guard canFillConversation(item), let conversation = item.record.conversation else { return false }
        return item.pane?.shell.fillPrompt(with: conversation.command) == true
    }

    func refillConversation(_ item: SpaceSession) {
        guard fillConversation(item) else { return }
        content.showNote(L10n.text("space.conversation.filled"))
    }

    func showConversationNoticeIfNeeded() {
        guard let project = selectedProject else { return }
        for item in project.shown where item.conversationNeedsNotice {
            item.conversationNeedsNotice = false
            content.showNote(L10n.text("space.conversation.continue"))
        }
    }
}
