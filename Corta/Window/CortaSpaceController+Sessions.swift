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

/// A project's sessions: starting, placing in the grid, hiding, ending.
extension CortaSpaceController {
    // MARK: - Sessions

    func session(for pane: ViewController) -> (project: SpaceProject, session: SpaceSession)? {
        for project in projects {
            if let session = project.sessions.first(where: { $0.pane === pane }) { return (project, session) }
        }
        return nil
    }

    func session(withID id: UUID) -> (project: SpaceProject, session: SpaceSession)? {
        for project in projects {
            if let session = project.sessions.first(where: { $0.id == id }) { return (project, session) }
        }
        return nil
    }

    func owns(_ pane: ViewController) -> Bool { session(for: pane) != nil }

    var focusedSession: SpaceSession? {
        guard let pane = host?.focusedPane else { return nil }
        return session(for: pane)?.session
    }

    /// A local session in the project folder (or `directory`), or a preset's.
    func newSession(preset: Preset? = nil, directory: String? = nil) {
        guard let project = selectedProject else {
            chooseProject()
            return
        }
        start(project)
        let configured = preset.flatMap { preset in
            ConfigurationStore.shared.configuration.presets.contains { $0.name == preset.name } ? preset.name : nil
        }
        var record = SpaceSessionRecord(
            number: project.nextNumber,
            directory: preset?.connectTarget == nil ? (directory ?? project.path) : nil,
            presetName: preset?.connectTarget == nil ? configured : nil,
            ssh: preset?.connectTarget)
        record.retainSSH = preset?.connectTarget != nil && preset?.retainSSH == true
        project.nextNumber += 1
        let session = SpaceSession(record: record)
        touch(session)
        project.sessions.append(session)
        if record.retainSSH == true { saveNow() }
        if project.maximized != nil { setMaximized(nil, in: project) }
        let placement = automaticPlacement(in: project)
        spawn(session, in: project, panelSize: plannedSize(of: placement, in: project), preset: preset)
        place(session, placement, in: project)
        focus(session)
        scheduleSave()
    }

    /// The SSH connect dialog, whose connection opens in this project.
    func project(containing session: SpaceSession) -> SpaceProject? {
        self.session(withID: session.id)?.project
    }

    /// Directory, branch, commit and dirty flag this pane already knows.
    func gitContext(for session: SpaceSession) -> [String] {
        var lines: [String] = []
        if let directory = session.pane?.session?.currentDirectory ?? session.record.directory,
           let line = AgentEnvelope.contextLine("cwd", directory) { lines.append(line) }
        if let line = AgentEnvelope.contextLine("pane", SpaceSessionPresentation(session: session).title) {
            lines.append(line)
        }
        if let facts = gitFacts[session.id] {
            if let line = AgentEnvelope.contextLine("branch", facts.name) { lines.append(line) }
            let directory = session.pane?.session?.currentDirectory ?? session.record.directory ?? ""
            if let head = GitStatusReader.commit(directory: directory),
               let line = AgentEnvelope.contextLine("head", head) { lines.append(line) }
            if let dirty = facts.changedFiles,
               let line = AgentEnvelope.contextLine("dirty", dirty > 0 ? "true" : "false") { lines.append(line) }
        }
        return lines
    }

    func syncAgentBus() {
        let members = projects.flatMap(\.members)
        let bound = Set(projects.flatMap(\.sessions).compactMap { session in
            session.conversationObservation?.processes.isEmpty == false ? session.id : nil
        })
        var shells: [pid_t: UUID] = [:]
        for session in projects.flatMap(\.sessions) {
            if let pid = session.pane?.session?.pty.processIdentifier { shells[pid] = session.id }
        }
        AgentHub.shared.sync(members: members, bound: bound, shells: shells)
        agentBus = AgentHub.shared.bus
    }

    @discardableResult
    func sendUserText(_ text: String, to member: AgentMemberRecord, from session: SpaceSession,
                      context: [String] = []) -> AgentDelivery {
        syncAgentBus()
        let limit = AgentEnvelope.bodyLimit
        var body = text
        var lines = context
        if body.utf8.count > limit {
            let original = body.utf8.count
            body = String(decoding: body.utf8.prefix(limit), as: UTF8.self)
            lines.append("truncated: \(original)")
        }
        let delivery = AgentHub.shared.deliverUser(to: member.id.uuidString, body: body, context: lines)
        content.showNote(L10n.format("space.member.sent", AgentHub.shared.deliveryName(delivery)))
        return delivery
    }

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
        guard isActive, let session = focusedSession, let text = session.pane?.commands.selectedText() else {
            content.showNote(L10n.text("space.member.none"))
            return
        }
        let others = (project(containing: session)?.members ?? []).filter { $0.sessionID != session.id }
        if others.count == 1 {
            sendUserText(text, to: others[0], from: session, context: gitContext(for: session))
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
            self.sendUserText(text, to: member, from: session, context: self.gitContext(for: session))
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

    func makeRemoteMember(_ session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project,
              let hostName = session.record.ssh?.displayName,
              let role = AgentMemberRecord.cleanRole(hostName) else { return }
        project.members.removeAll { $0.sessionID == session.id }
        project.members.append(AgentMemberRecord(role: role, sessionID: session.id, host: hostName))
        scheduleSave()
        refreshNow()
    }

    func removeMember(_ session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project else { return }
        syncAgentBus()
        AgentHub.shared.dropInbox(sessionID: session.id)
        project.members.removeAll { $0.sessionID == session.id }
        scheduleSave()
        refreshNow()
    }

    func promptWorktree(from session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.worktree.prompt")
        alert.informativeText = L10n.text("space.worktree.detail")
        let name = NSTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        name.stringValue = gitFacts[session.id]?.detached == false ? (gitFacts[session.id]?.name ?? "topic") : "topic"
        let branch = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        branch.placeholderString = L10n.text("space.worktree.branchOptional")
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        name.frame = NSRect(x: 0, y: 28, width: 280, height: 24)
        branch.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        stack.addSubview(name)
        stack.addSubview(branch)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("space.worktree.new"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newBranch = !branch.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let branchName = newBranch ? branch.stringValue : name.stringValue
            guard let location = WorktreeCommand.location(projectPath: project.path, name: name.stringValue),
                  let command = WorktreeCommand.line(location: location, branch: branchName, newBranch: newBranch)
            else {
                self.content.showNote(L10n.text("space.worktree.rejected"))
                return
            }
            self.newSession(directory: project.path)
            self.fillWhenReady(command: command, note: "space.worktree.filled")
        }
    }

    func revealWorktreeMain(_ session: SpaceSession) {
        guard let path = gitFacts[session.id]?.mainRepository else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func fillWhenReady(command: String, note: String) {
        guard let session = focusedSession else { return }
        Task { @MainActor [weak self, weak session] in
            let deadline = SuspendingClock.now.advanced(by: .seconds(10))
            while SuspendingClock.now < deadline {
                if session?.pane?.shell.fillPrompt(with: command) == true {
                    self?.content.showNote(L10n.text(note))
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

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
        selectProject(project)
        start(project)
        for (index, built) in template.sessions(in: project.path).enumerated() {
            var record = built.0
            record.number = project.nextNumber
            project.nextNumber += 1
            let session = SpaceSession(record: record)
            project.sessions.append(session)
            if project.maximized != nil { setMaximized(nil, in: project) }
            let placement = automaticPlacement(in: project)
            spawn(session, in: project, panelSize: plannedSize(of: placement, in: project))
            place(session, placement, in: project)
            focus(session)
            if let agent = built.1 { fillWhenReady(command: agent, note: "space.template.filled") }
            if let role = template.sessions[index].memberRole, let clean = AgentMemberRecord.cleanRole(role) {
                project.members.append(AgentMemberRecord(
                    role: clean, sessionID: session.id,
                    nudgeEnabled: template.sessions[index].nudgeEnabled ?? true))
            }
        }
        scheduleSave()
        content.showNote(L10n.format("space.template.applied", template.name))
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

    func connectSession() {
        RemoteConnectController.shared.show(.ssh, sender: self, sessionDestination: { [weak self] preset in
            self?.newSession(preset: preset)
        })
    }

    /// Puts the session on screen — splitting the roomiest panel, or in the
    /// least recently used one's place when there is no room — and focuses it.
    func show(_ session: SpaceSession) {
        guard let (project, _) = self.session(withID: session.id) else { return }
        if project !== selectedProject { selectProject(project) }
        // Already on screen: only focus moves, and nothing redraws.
        if project.shown.contains(session), project.maximized == nil || project.maximized === session {
            focus(session)
            return
        }
        registerLayoutUndo(in: project, name: L10n.text("space.undo.show"))
        if project.maximized != nil { setMaximized(nil, in: project) }
        if !project.shown.contains(session) { place(session, automaticPlacement(in: project), in: project) }
        focus(session)
        announce(session)
        scheduleSave()
    }

    /// "Show in Panel ▸": the session takes that panel's place.
    func show(_ session: SpaceSession, in target: SpaceSession) {
        guard let project = selectedProject, project.sessions.contains(session), project.shown.contains(target),
              let panel = panel(for: target) else { return }
        registerLayoutUndo(in: project, name: L10n.text("space.undo.show"))
        if project.maximized != nil { setMaximized(nil, in: project) }
        place(session, .replace(panel), in: project)
        focus(session)
        announce(session)
        scheduleSave()
    }

    /// A session dropped on a panel: on an edge, beside it; in the middle,
    /// in its place (two on screen swap).
    func drop(_ session: SpaceSession, on target: SpacePaneView, edge: SpaceGrid.Edge?) {
        guard let project = selectedProject, project.sessions.contains(session) else { return }
        registerLayoutUndo(in: project, name: L10n.text("space.undo.show"))
        if let edge, canDrop(session, on: target, edge: edge) {
            place(session, .split(target, edge), in: project)
        } else {
            place(session, .replace(target), in: project)
        }
        focus(session)
        announce(session)
        scheduleSave()
    }

    /// A session dropped on an empty grid.
    func dropOnEmptyGrid(_ session: SpaceSession) {
        guard let project = selectedProject, project.sessions.contains(session), project.tree == nil else { return }
        place(session, .root, in: project)
        focus(session)
        scheduleSave()
    }

    // MARK: - Remote files

    /// Whether the session is on a remote host whose files can be browsed.
    func canBrowseFiles(of session: SpaceSession) -> Bool {
        session.pane?.remote.canBrowseFiles == true
    }

    /// The SFTP browser for the session's host, at the directory its shell
    /// reported — the browser's own consent rules, as from the Shell menu.
    func browseFiles(of session: SpaceSession) {
        guard let pane = session.pane, pane.remote.canBrowseFiles,
              let (project, _) = self.session(withID: session.id) else { return }
        SFTPBrowserController.show(for: pane.remote.state, project: project.name)
    }

    /// The hosts the project's sessions connect to through the connect
    /// dialog — typed by the user, so consent to connect — once each. An
    /// `ssh` typed at a prompt leaves no record here, and is not listed.
    func remoteHosts(of project: SpaceProject) -> [SSHTarget] {
        var seen = Set<String>()
        return project.sessions.compactMap(\.record.ssh).filter { seen.insert($0.key).inserted }
    }

    func browseFiles(on target: SSHTarget, for project: SpaceProject) {
        SFTPBrowserController.open(target, project: project.name)
    }

    /// The user's name for the session; empty goes back to the program's.
    func rename(_ session: SpaceSession, to name: String?) {
        session.record.name = SpaceSessionRecord.cleanName(name)
        refreshNow()
        scheduleSave()
    }

    /// Takes the panel off screen; the session keeps running and its
    /// neighbour takes the space.
    func hide(_ session: SpaceSession) {
        guard let project = selectedProject, project.shown.contains(session), let panel = panel(for: session)
        else { return }
        registerLayoutUndo(in: project, name: L10n.text("space.undo.hide"))
        if project.maximized === session { setMaximized(nil, in: project) }
        remove(panel, from: project)
        installRoot(of: project)
        resizeOffScreenSessions()
        focus(project.shown.max { $0.lastUsed < $1.lastUsed })
        scheduleSave()
    }

    func toggleMaximize(_ session: SpaceSession? = nil) {
        guard let project = selectedProject, let session = session ?? focusedSession,
              project.shown.contains(session) else { return }
        setMaximized(project.maximized === session ? nil : session, in: project)
        focus(session)
    }

    /// Ends the session, asking first if a program is running in it.
    func endSession(_ session: SpaceSession) {
        guard let host else { return }
        if session.record.retainSSH == true {
            confirmRetainedRemoval([session]) { [weak self, weak session] in
                guard let session else { return }
                self?.remove(session)
            }
            return
        }
        guard let pane = session.pane else {
            remove(session)
            return
        }
        host.confirmClose(
            of: pane.session?.hasForegroundJob == true ? [pane] : [],
            scope: L10n.text("close.scope.pane"), in: host.toolbarWindow
        ) { [weak self, weak session] confirmed in
            guard confirmed, let self, let session else { return }
            self.remove(session)
        }
    }

    /// The pane's session is over (its shell exited and was closed).
    func removeSession(_ pane: ViewController) {
        guard let (_, session) = session(for: pane) else { return }
        if session.record.retainSSH == true {
            confirmRetainedRemoval([session]) { [weak self, weak session] in
                guard let session else { return }
                self?.remove(session)
            }
        } else { remove(session) }
    }

    private func remove(_ session: SpaceSession) {
        guard let (project, _) = self.session(withID: session.id) else { return }
        let wasFocused = host?.focusedPane != nil && host?.focusedPane === session.pane
        if project.maximized === session { setMaximized(nil, in: project) }
        if let panel = panels[ObjectIdentifier(session)] { remove(panel, from: project) }
        discard(session)
        project.sessions.removeAll { $0 === session }
        if project === selectedProject, isActive {
            installRoot(of: project)
            resizeOffScreenSessions()
            if wasFocused || host?.focusedPane == nil { focus(project.shown.max { $0.lastUsed < $1.lastUsed }) }
        }
        refreshNow()
        scheduleSave()
    }

    func discard(_ session: SpaceSession) {
        guard let pane = session.pane else { return }
        session.pane = nil
        panels.removeValue(forKey: ObjectIdentifier(session))?.removeFromSuperview()
        if host?.focusedPane === pane { host?.focusedPane = nil }
        pane.teardown()
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        AgentDirectory.refresh()
    }

    /// A remote member's connection forwards the message socket and installs a `/tmp` client.
    func remotePreset(_ preset: Preset?, session: SpaceSession) -> Preset? {
        guard var preset, let tmux = preset.remoteTmux, let target = preset.connectTarget,
              ConfigurationStore.shared.configuration.agentMessages,
              let member = member(of: session), member.host != nil,
              let socket = AgentHub.shared.socketPath else { return preset }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        AgentHub.shared.rememberRemote(token: token, member: member.id)
        var extras = RemoteTmux.Extras()
        extras.environmentName = "CORTA_MEMBER_TOKEN"
        extras.environmentValue = token
        extras.reverseRemote = "/tmp/corta-" + token + ".sock"
        extras.reverseLocal = socket
        extras.installRemoteClient = true
        preset.arguments = SSHDestination.retainedArguments(
            for: target, tmux: tmux, preamble: preset.retainedSSHPreamble,
            commandLeadIn: preset.retainedCommandLeadIn, extras: extras)
        return preset
    }

    func spawn(_ session: SpaceSession, in project: SpaceProject, panelSize: CGSize, preset: Preset? = nil) {
        guard let host, session.pane == nil else { return }
        let record = session.record
        var resolved = record.ssh.map { target in
            makeSSHPreset(target, record.retainSSH == true ? RemoteTmux(id: record.id) : nil)
        }
            ?? preset
            ?? record.presetName.flatMap { name in
                ConfigurationStore.shared.configuration.presets.first { $0.name == name }
            }
        resolved?.tmuxPreviouslyEstablished = record.tmuxEstablished == true
        let template = host.focusedPane ?? host.panes.first
        let terminalSize = CGSize(width: panelSize.width, height: panelSize.height - SpacePaneView.headerHeight)
        let grid = terminalSize.width > 0 && terminalSize.height > 0
            ? template?.gridSize(fittingBelowChrome: terminalSize) : nil
        let pane = host.makePane(
            workingDirectory: record.ssh == nil ? (record.directory ?? project.path) : nil,
            initialGridSize: grid, preset: remotePreset(resolved, session: session),
            agentPaneID: session.id)
        // The window's temporary font zoom applies to new sessions too.
        if let template {
            pane.setFontSize(template.fontSize)
            pane.isFontSizeZoomed = template.isFontSizeZoomed
        }
        session.pane = pane
        pane.remote.onTmuxReport = { [weak self, weak session] report in
            guard let self, let session else { return }
            if report.established {
                session.record.tmuxEstablished = true
                if let member = self.member(of: session), member.host != nil {
                    AgentHub.shared.markRemoteReady(member.id)
                }
            }
            self.refreshNow()
            self.scheduleSave()
        }
    }
}
