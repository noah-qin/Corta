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
    func saveTemplate(of project: SpaceProject) {
        let alert = NSAlert()
        alert.messageText = L10n.text("space.template.save")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.template.save"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { response in
            guard response == .alertFirstButtonReturn,
                  let name = AgentMemberRecord.cleanRole(field.stringValue) else { return }
            var file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
            let template = SpaceTemplate.capture(
                name: name, projectPath: project.path, sessions: project.sessions.map(\.currentRecord),
                members: project.members, layout: project.layout)
            file.templates.removeAll { $0.name == name }
            file.templates.append(template)
            try? file.save(to: SpaceTemplateFile.url)
        }
    }

    func applyTemplate(to project: SpaceProject) {
        let file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
        guard !file.templates.isEmpty else {
            content.showNote(L10n.text("space.template.empty"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.template.apply")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = file.templates.count == 1 ? file.templates[0].name : ""
        alert.informativeText = file.templates.map(\.name).joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.template.apply"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self, weak project] response in
            guard response == .alertFirstButtonReturn, let self, let project,
                  let template = file.templates.first(where: { $0.name == field.stringValue }) else {
                self?.content.showNote(L10n.text("space.template.empty"))
                return
            }
            self.apply(template, to: project)
        }
    }

    func apply(_ template: SpaceTemplate, to project: SpaceProject) {
        let outside = template.externalDirectories(in: project.path)
        guard outside.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.text("space.template.outside")
            alert.informativeText = outside.joined(separator: "\n")
            alert.addButton(withTitle: L10n.text("common.cancel"))
            alert.addButton(withTitle: L10n.text("space.template.apply"))
            presentAlert(alert, host?.toolbarWindow) { [weak self] result in
                if result == .alertSecondButtonReturn { self?.applyConfirmed(template, to: project) }
            }
            return
        }
        applyConfirmed(template, to: project)
    }

    func applyConfirmed(_ template: SpaceTemplate, to project: SpaceProject) {
        selectProject(project)
        start(project)
        let offset = project.sessions.count
        for (index, built) in template.sessions(in: project.path).enumerated() {
            var record = built.0
            record.number = project.nextNumber
            project.nextNumber += 1
            let session = SpaceSession(record: record)
            project.sessions.append(session)
            if let role = template.sessions[index].memberRole, let clean = AgentMemberRecord.cleanRole(role) {
                project.members.append(AgentMemberRecord(
                    role: clean, sessionID: session.id,
                    nudgeEnabled: template.sessions[index].nudgeEnabled ?? true))
            }
        }
        let shifted = template.layout?.mapPanels { $0 + offset }
        let sizes = shifted?.panelSizes(in: gridArea) ?? [:]
        let added = Array(project.sessions.dropFirst(offset))
        for (index, built) in template.sessions(in: project.path).enumerated() where added[index].record.ssh == nil {
            let session = added[index]
            spawn(session, in: project, panelSize: sizes[offset + index] ?? gridArea)
            if let agent = built.1 {
                fillWhenReady(command: agent, note: "space.template.filled", session: session)
            }
        }
        let original = project.sessions.map(\.id)
        connectTemplateSessions(added.filter { $0.record.ssh != nil }, in: project) { [weak self, weak project] in
            guard let self, let project else { return }
            if let shifted {
                let remapped = shifted.mapPanels { index in
                    guard original.indices.contains(index) else { return -1 }
                    return project.sessions.firstIndex { $0.id == original[index] } ?? -1
                }
                project.tree?.root.removeFromSuperview()
                project.tree = nil
                project.pendingLayout = remapped.validated(sessionCount: project.sessions.count)
            }
            self.rebuildGrid()
            self.focus(project.shown.first)
            self.scheduleSave()
            self.content.showNote(L10n.format("space.template.applied", template.name))
        }
    }

    /// One connection sheet at a time; cancellation removes only that pending session.
    private func connectTemplateSessions(_ remaining: [SpaceSession], in project: SpaceProject,
                                         finished: @escaping () -> Void) {
        guard let session = remaining.first, let target = session.record.ssh else { finished(); return }
        let next = { [weak self, weak project] in
            DispatchQueue.main.async {
                guard let self, let project else { return }
                self.connectTemplateSessions(Array(remaining.dropFirst()), in: project, finished: finished)
            }
        }
        RemoteConnectController.shared.show(.ssh, sender: self, sessionDestination: { [weak self] preset in
            session.record.ssh = preset.connectTarget
            session.record.retainSSH = preset.retainSSH
            self?.spawn(session, in: project, panelSize: self?.gridArea ?? .zero, preset: preset)
            next()
        }, initialTarget: target, initialRetention: session.record.retainSSH ?? true, onCancel: {
            project.sessions.removeAll { $0 === session }
            project.members.removeAll { $0.sessionID == session.id }
            next()
        })
    }

    func renameTemplate() {
        let names = SpaceTemplateFile.load(from: SpaceTemplateFile.url).templates.map(\.name)
        guard !names.isEmpty else {
            content.showNote(L10n.text("space.template.empty"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.template.rename")
        alert.informativeText = names.joined(separator: ", ")
        let from = NSTextField(frame: NSRect(x: 0, y: 28, width: 240, height: 24))
        let to = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        to.placeholderString = L10n.text("space.template.renameTo")
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        stack.addSubview(from)
        stack.addSubview(to)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("space.template.rename"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { response in
            guard response == .alertFirstButtonReturn,
                  let name = AgentMemberRecord.cleanRole(to.stringValue) else { return }
            var file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
            guard let index = file.templates.firstIndex(where: { $0.name == from.stringValue }) else { return }
            file.templates[index].name = name
            try? file.save(to: SpaceTemplateFile.url)
        }
    }

    func showTemplate() {
        let file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
        guard !file.templates.isEmpty else {
            content.showNote(L10n.text("space.template.empty"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.template.show")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = file.templates[0].name
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.template.show"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let template = file.templates.first(where: { $0.name == field.stringValue }),
                  let data = try? JSONEncoder().encode(template) else { return }
            let text = String(decoding: data, as: UTF8.self)
            let shown = NSAlert()
            shown.messageText = template.name
            shown.informativeText = text
            shown.addButton(withTitle: L10n.text("space.member.copy"))
            shown.addButton(withTitle: L10n.text("space.member.cancel"))
            self.presentAlert(shown, self.host?.toolbarWindow) { response in
                guard response == .alertFirstButtonReturn else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    func deleteTemplate() {
        let file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
        guard !file.templates.isEmpty else {
            content.showNote(L10n.text("space.template.empty"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.template.delete")
        alert.informativeText = file.templates.map(\.name).joined(separator: ", ")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.template.delete"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            var file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
            let before = file.templates.count
            file.templates.removeAll { $0.name == field.stringValue }
            guard file.templates.count < before else { return }
            try? file.save(to: SpaceTemplateFile.url)
        }
    }

}
