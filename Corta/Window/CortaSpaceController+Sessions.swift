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
    func member(of session: SpaceSession) -> AgentMemberRecord? {
        self.session(withID: session.id)?.project.members.first { $0.sessionID == session.id }
    }

    func makeMember(_ session: SpaceSession) {
        guard let (project, _) = self.session(withID: session.id), session.record.ssh == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.member.prompt")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = session.record.conversation?.kind.rawValue ?? "member"
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("space.member.add"))
        alert.addButton(withTitle: L10n.text("space.member.cancel"))
        presentAlert(alert, host?.toolbarWindow) { [weak self, weak project] response in
            guard response == .alertFirstButtonReturn, let self, let project,
                  let role = AgentMemberRecord.cleanRole(field.stringValue) else { return }
            project.members.removeAll { $0.sessionID == session.id }
            project.members.append(AgentMemberRecord(role: role, sessionID: session.id))
            self.scheduleSave()
            self.refreshNow()
        }
    }

    func setMemberPaused(_ session: SpaceSession, paused: Bool) {
        guard let project = self.session(withID: session.id)?.project,
              let index = project.members.firstIndex(where: { $0.sessionID == session.id }) else { return }
        project.members[index].paused = paused
        if paused { /* inbox drop is the bus's job when it is attached */ }
        scheduleSave()
    }

    func removeMember(_ session: SpaceSession) {
        guard let project = self.session(withID: session.id)?.project else { return }
        project.members.removeAll { $0.sessionID == session.id }
        scheduleSave()
        refreshNow()
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
            initialGridSize: grid, preset: resolved)
        // The window's temporary font zoom applies to new sessions too.
        if let template {
            pane.setFontSize(template.fontSize)
            pane.isFontSizeZoomed = template.isFontSizeZoomed
        }
        session.pane = pane
        pane.remote.onTmuxReport = { [weak self, weak session] report in
            guard let self, let session else { return }
            if report.established { session.record.tmuxEstablished = true }
            self.refreshNow()
            self.scheduleSave()
        }
    }
}
