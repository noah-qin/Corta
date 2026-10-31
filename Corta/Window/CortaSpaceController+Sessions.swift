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
        guard session.record.ssh == nil else { return [] }
        var lines: [String] = []
        if let directory = session.pane?.session?.currentDirectory ?? session.record.directory,
           let line = AgentEnvelope.contextLine("cwd", directory) { lines.append(line) }
        if let line = AgentEnvelope.contextLine("pane", SpaceSessionPresentation(session: session).title) {
            lines.append(line)
        }
        if let facts = gitFacts[session.id] {
            if let line = AgentEnvelope.contextLine("branch", facts.name) { lines.append(line) }
            if let head = facts.commit,
               let line = AgentEnvelope.contextLine("head", head) { lines.append(line) }
            if let dirty = facts.changedFiles,
               let line = AgentEnvelope.contextLine("dirty", dirty > 0 ? "true" : "false") { lines.append(line) }
        }
        return lines
    }

    func syncAgentBus() {
        guard Self.owner == nil || Self.owner === self else { return }
        configureAgentHubCallbacks()
        for session in projects.flatMap(\.sessions) where session.record.ssh != nil {
            if session.pane?.session?.pty.exitStatus != nil, let member = member(of: session) {
                AgentHub.shared.disconnectRemote(member.id)
            }
        }
        let members = projects.flatMap(\.members)
        let configured = ConfigurationStore.shared.configuration.agentProcesses
        let bound = Set(projects.flatMap(\.sessions).compactMap { session -> UUID? in
            if session.conversationObservation?.processes.isEmpty == false { return session.id }
            if agentActivities[session.id]?.kind != nil { return session.id }
            if let name = session.pane?.session?.pty.activeProcessName,
               AgentProcessNames.matches(name, configured: configured) {
                return session.id
            }
            return nil
        })
        var shells: [pid_t: UUID] = [:]
        for session in projects.flatMap(\.sessions) {
            if let pid = session.pane?.session?.pty.processIdentifier { shells[pid] = session.id }
        }
        var projectsByMember: [UUID: String] = [:]
        for project in projects {
            for member in project.members { projectsByMember[member.id] = project.path }
        }
        AgentHub.shared.sync(members: members, bound: bound, shells: shells, projects: projectsByMember)
        agentBus = AgentHub.shared.bus
    }

    @discardableResult
    func sendUserText(_ text: String, to member: AgentMemberRecord, from session: SpaceSession,
                      context: [String] = []) -> AgentDelivery {
        syncAgentBus()
        guard ConfigurationStore.shared.configuration.agentMessages else { return .refused("disabled") }
        let limit = AgentEnvelope.bodyLimit - 4096
        var body = text
        var lines = context
        if body.utf8.count > limit {
            let original = body.utf8.count
            body = AgentEnvelope.prefixUTF8(body, limit: limit)
            lines.append("truncated: \(original)")
        }
        let delivery = AgentHub.shared.deliverUser(to: member.id.uuidString, body: body, context: lines,
                                                  pane: SpaceSessionPresentation(session: session).title,
                                                      source: session.id)
        content.showNote(L10n.format("space.member.sent", AgentHub.shared.deliveryName(delivery)))
        return delivery
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
        if let member = member(of: session), member.host != nil { AgentHub.shared.disconnectRemote(member.id) }
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
              AgentHub.shared.socketPath != nil else { return preset }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        AgentHub.shared.rememberRemote(token: token, member: member.id)
        guard let socket = AgentHub.shared.remoteEndpoint(token: token, member: member.id,
                                                         tmux: tmux.sessionName) else { return preset }
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
        pane.remote.onTmuxReport = { [weak self, weak session, weak pane] report in
            guard let self, let session, let pane else { return }
            self.noteTmuxResult(report, session: session, pane: pane)
        }
    }
}
