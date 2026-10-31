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
    func member(of session: SpaceSession) -> AgentMemberRecord? {
        self.session(withID: session.id)?.project.members.first { $0.sessionID == session.id }
    }

    func makeMember(_ session: SpaceSession) {
        guard let (project, _) = self.session(withID: session.id), session.record.ssh == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.prompt")
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        field.stringValue = session.record.conversation?.kind.rawValue ?? "member"
        let nudge = NSButton(checkboxWithTitle: L10n.text("space.member.nudge"), target: nil, action: nil)
        nudge.state = .on
        nudge.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        stack.addSubview(field)
        stack.addSubview(nudge)
        alert.accessoryView = stack
        alert.informativeText = L10n.text("space.member.nudgeDetail")
        alert.addButton(withTitle: L10n.text("space.member.add"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self, weak project] response in
            guard response == .alertFirstButtonReturn, let self, let project,
                  let role = AgentMemberRecord.cleanRole(field.stringValue) else { return }
            project.members.removeAll { $0.sessionID == session.id }
            project.members.append(AgentMemberRecord(
                role: role, sessionID: session.id, nudgeEnabled: nudge.state == .on))
            self.scheduleSave()
            self.refreshNow()
            self.copyIntroduction(session)
        }
    }

    func sendSelectionFromPalette() {
        guard ConfigurationStore.shared.configuration.agentMessages, isActive, let session = focusedSession,
            let text = session.pane?.commands.selectedText() else {
            content.showNote(L10n.text("space.member.none"))
            return
        }
        let others = (project(containing: session)?.members ?? []).filter { $0.sessionID != session.id }
        guard !others.isEmpty else {
            content.showNote(L10n.text("space.member.none"))
            return
        }
        if others.count == 1 {
            sendSelection(text, to: others[0], from: session)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("command.sendSelectionToMember")
        alert.informativeText = others.map { $0.role + " " + AgentEnvelope.shortID($0.id) }.joined(separator: "\n")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.member.send"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let member = others.first(where: {
                      AgentEnvelope.shortID($0.id) == field.stringValue || $0.role == field.stringValue
                  }) else { return }
            self.sendSelection(text, to: member, from: session)
        }
    }

    func copyIntroduction(_ session: SpaceSession) {
        syncAgentBus()
        guard let text = AgentHub.shared.introduction(sessionID: session.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        content.showNote(L10n.text("space.member.copied"))
    }

    func showHistory(_ session: SpaceSession) {
        syncAgentBus()
        let text = AgentHub.shared.historyText(sessionID: session.id)
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.history")
        alert.informativeText = text.isEmpty ? L10n.text("space.member.historyEmpty") : text
        alert.addButton(withTitle: L10n.text("space.member.copy"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { response in
            guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func copyUnread(_ session: SpaceSession) {
        syncAgentBus()
        let text = AgentHub.shared.unreadText(sessionID: session.id)
        guard !text.isEmpty else {
            content.showNote(L10n.text("space.member.historyEmpty"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        content.showNote(L10n.text("space.member.copied"))
    }

    func setMemberPaused(_ session: SpaceSession, paused: Bool) {
        guard let project = self.session(withID: session.id)?.project,
              let index = project.members.firstIndex(where: { $0.sessionID == session.id }) else { return }
        project.members[index].paused = paused
        if paused {
            syncAgentBus()
            AgentHub.shared.dropInbox(sessionID: session.id)
        }
        scheduleSave()
    }

    func removeMember(_ session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project else { return }
        syncAgentBus()
        AgentHub.shared.dropInbox(sessionID: session.id)
        project.members.removeAll { $0.sessionID == session.id }
        scheduleSave()
        refreshNow()
    }

}

extension CortaSpaceController {
    func editMember(_ session: SpaceSession) {
        guard let project = project(containing: session),
              let index = project.members.firstIndex(where: { $0.sessionID == session.id }) else { return }
        let member = project.members[index]
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.edit")
        let role = NSTextField(string: member.role)
        let nudge = NSButton(checkboxWithTitle: L10n.text("space.member.nudge"), target: nil, action: nil)
        nudge.state = member.nudgeEnabled ? .on : .off
        let context = NSButton(checkboxWithTitle: L10n.text("space.member.context"), target: nil, action: nil)
        context.state = member.contextEnabled == true ? .on : .off
        let selection = NSButton(checkboxWithTitle: L10n.text("space.member.selectionContext"), target: nil,
            action: nil)
        selection.state = member.selectionContextEnabled == false ? .off : .on
        let thread = NSTextField(string: member.codexThreadName ?? "")
        thread.placeholderString = L10n.text("space.member.codexName")
        let stack = NSStackView(views: [role, nudge, context, selection, thread])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        alert.accessoryView = stack
        alert.informativeText = L10n.text("space.member.nudgeDetail")
        alert.addButton(withTitle: L10n.text("space.member.save"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self, weak project] response in
            guard response == .alertFirstButtonReturn, let self, let project,
                  let found = project.members.firstIndex(where: { $0.id == member.id }),
                  let clean = AgentMemberRecord.cleanRole(role.stringValue) else { return }
            project.members[found].role = clean
            project.members[found].nudgeEnabled = nudge.state == .on
            project.members[found].contextEnabled = context.state == .on
            project.members[found].selectionContextEnabled = selection.state == .on
            project.members[found].codexThreadName = thread.stringValue.isEmpty ? nil : thread.stringValue
            self.syncAgentBus()
            self.scheduleSave()
            self.refreshNow()
        }
    }

    func sendSelection(_ text: String, to member: AgentMemberRecord, from session: SpaceSession) {
        let context = self.member(of: session)?.selectionContextEnabled == false ? [] : gitContext(for: session)
        guard NSEvent.modifierFlags.contains(.shift) else {
            sendUserText(text, to: member, from: session, context: context)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.preface")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.member.send"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let body = field.stringValue.isEmpty ? text : field.stringValue + "\n\n" + text
            self?.sendUserText(body, to: member, from: session, context: context)
        }
    }
}

extension CortaSpaceController {
    func showMemberDirectory(for project: SpaceProject) {
        syncAgentBus()
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.directory")
        alert.informativeText = project.members.map {
            $0.role + " (" + AgentEnvelope.shortID($0.id) + ") · " + AgentHub.shared.capability($0)
                + ($0.host.map { " · " + $0 } ?? "")
        }.joined(separator: "\n")
        if project.members.isEmpty { alert.informativeText = L10n.text("space.member.none") }
        alert.addButton(withTitle: L10n.text("common.close"))
        presentAlert(alert, host?.toolbarWindow) { _ in }
    }
}
