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
import Darwin

/// Which session is in use, and keeping the chrome that shows it current.
extension CortaSpaceController {
    // MARK: - Focus and use

    /// Most recent use; the grid replaces the lowest.
    func touch(_ session: SpaceSession) {
        usageClock += 1
        session.lastUsed = usageClock
    }

    func focus(_ session: SpaceSession?) {
        guard let host else { return }
        guard let session, let pane = session.pane, pane.view.window != nil else {
            if session == nil || session?.pane == nil { host.focusedPane = nil }
            refreshNow()
            return
        }
        host.focusedPane = pane
        selectedProject?.focused = session
        pane.agents.clearNotedAttention()
        touch(session)
        host.toolbarWindow?.makeFirstResponder(pane.terminalView)
        for other in host.panes { other.focus.applyAppearance() }
        scheduleRefresh()
    }

    /// Focus moved between panes. Both count as used: the one left behind
    /// was in use until now.
    func noteFocus(_ pane: ViewController, previous: ViewController?) {
        guard isActive, !isRebuildingGrid else { return }
        if let previous, let (_, session) = session(for: previous) { touch(session) }
        guard let (project, session) = session(for: pane) else { return }
        touch(session)
        project.focused = session
        scheduleRefresh()
    }

    /// A batch of output: titles in the sidebar may have changed. At most two
    /// refreshes a second, whatever the output rate.
    func noteOutput(from pane: ViewController? = nil) {
        if let pane, let session = session(for: pane)?.session { lastAgentOutput[session.id] = .now }
        guard isActive, !isOutputRefreshScheduled else { return }
        isOutputRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isOutputRefreshScheduled = false
            self.refreshNow()
        }
    }

    // MARK: - Chrome

    func scheduleRefresh() {
        guard isActive, !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshScheduled = false
            self.refreshNow()
        }
    }

    func refreshNow() {
        guard isActive else {
            sidebar.setWaitingCount(0)
            gitMonitor.update([:])
            updateAttentionBadge(ordered: [])
            return
        }
        let ordered = waitingSessionIDs()
        let typing = focusedSession?.pane?.terminalView?.lastUserInput
            .map { SuspendingClock.now - $0 < .seconds(3) } ?? false
        let previousHead = advancedWaitingSession
        if previousHead != focusedSession?.id { advancedWaitingSession = nil }
        if ConfigurationStore.shared.configuration.waitingQueueAutoAdvance,
           let previousHead, !ordered.contains(previousHead), focusedSession?.id == previousHead,
           let next = ordered.first, let session = session(withID: next)?.session,
           !typing {
            advancedWaitingSession = nil
            DispatchQueue.main.async { [weak self] in self?.show(session) }
        }
        if let focused = focusedSession?.id, ordered.contains(focused) { advancedWaitingSession = focused }
        sidebar.setWaitingCount(ordered.count)
        noteGitDirectories()
        syncAgentBus()
        AgentHub.shared.nudgePending()
        sidebar.reload()
        for panel in panels.values where panel.window != nil { panel.update() }
        content.update()
        showConversationNoticeIfNeeded()
        updateAttentionBadge(ordered: ordered)
    }

    func wakeSnapshot(for sessionID: UUID) -> AgentWakeSnapshot? {
        guard let session = session(withID: sessionID)?.session, let pane = session.pane,
              let terminal = pane.session else { return nil }
        let observation = session.conversationObservation
        let kind = observation?.conversation.kind.rawValue
        let group = terminal.pty.foregroundProcessGroup
        let configured = ConfigurationStore.shared.configuration.agentProcesses
        let foregroundName = terminal.pty.activeProcessName
        let namedAgent = foregroundName.map { AgentProcessNames.matches($0, configured: configured) } == true
            && group != terminal.pty.processIdentifier
        let activity = agentActivities[sessionID]
        let observedAgent = observation?.processes.contains { activity?.processes.contains($0.pid) == true } == true
        let foreground = activity?.group == group && (observedAgent || activity?.kind != nil || namedAgent)
        let status = pane.agents.status
        let signalledIdle = status?.state == .idle || status?.state == .done
        let hasAuthoritativeState = status?.state == .working || status?.state == .blocked
        let quiet = lastAgentOutput[sessionID].map { SuspendingClock.now - $0 >= .seconds(2) } ?? false
        let idle = signalledIdle || (!hasAuthoritativeState && idleAgents.contains(sessionID) && quiet)
        let typing = pane.terminalView?.lastUserInput.map { SuspendingClock.now - $0 < .seconds(3) } ?? false
        let member = member(of: session)
        let agent = observation?.processes.first
        let gate = AgentNudgeGate(
            enabled: ConfigurationStore.shared.configuration.agentMessages && member?.nudgeEnabled == true,
            foregroundIsAgent: foreground, idle: idle, userIdle: !typing,
            composing: pane.terminalView?.hasMarkedText() == true || pane.terminalView?.hasUnsubmittedInput == true,
            bracketedPaste: terminal.hasPendingPaste || terminal.isPasteInFlight,
            nudgesThisMinute: AgentHub.shared.bus.nudges(for: member?.id ?? UUID(),
                now: Date().timeIntervalSinceReferenceDate))
        return AgentWakeSnapshot(
            kind: kind,
            claudeSocket: agent.flatMap { Self.claudeSocket(of: $0.pid) },
            codexExecutable: kind == "codex" ? agent.flatMap { Self.executablePath(of: $0.pid) } : nil,
            codexThread: observation?.conversation.id?.uuidString ?? member?.codexThreadName,
            gate: gate)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Claude's inbox is the environment path or a Unix socket in its private directory.
    private static func claudeSocket(of pid: pid_t) -> String? {
        if let value = ConversationProcess.environmentValue(pid, key: "CLAUDE_CODE_MESSAGING_SOCKET"),
           AgentPush.acceptedSocket(value) {
            return value
        }
        return Self.unixSockets(of: pid).first(where: AgentPush.acceptedSocket)
    }

    private static func unixSockets(of pid: pid_t) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard bytes > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_UN) else { continue }
            let path = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path.hasPrefix("/") { paths.append(path) }
        }
        return paths
    }

    func writeNudge(to sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID)?.session,
              let terminal = session.pane?.session else { return false }
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
              let submit = TerminalView.bytes(for: key, enhancements: terminal.keyboardEnhancements,
                                              newLineMode: paneIsNewLineMode(session)) else { return false }
        guard terminal.write(Array(AgentEnvelope.nudgeText.utf8)) == .accepted else { return false }
        let revision = session.pane?.terminalView?.userInputRevision
        let group = terminal.pty.foregroundProcessGroup
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak session] in
            guard let session, session.pane?.session === terminal,
                  session.pane?.terminalView?.userInputRevision == revision,
                  terminal.pty.foregroundProcessGroup == group else { return }
            _ = terminal.write(submit)
        }
        return true
    }

    private func paneIsNewLineMode(_ session: SpaceSession) -> Bool {
        session.pane?.terminalView?.isNewLineMode?() ?? false
    }

    func noteGitDirectories() {
        var directories: [UUID: String] = [:]
        for session in projects.flatMap(\.sessions) where session.record.ssh == nil {
            if let directory = session.pane?.session?.currentDirectory ?? session.record.directory {
                directories[session.id] = directory
            }
        }
        gitMonitor.update(directories)
    }

    func gitRow(for id: UUID) -> SpaceSessionCell.Content.GitRow? {
        guard let facts = gitFacts[id] else { return nil }
        var text = facts.detached ? L10n.format("space.git.detached", facts.name) : facts.name
        if facts.worktree { text += " · " + L10n.text("space.git.worktree") }
        var tip = text
        if facts.unchecked {
            tip += "\n" + L10n.text("space.git.large")
        } else if let count = facts.changedFiles, count > 0 {
            text += " · \(count)"
            tip += "\n" + L10n.format("space.git.dirty", count)
        }
        if let main = facts.mainRepository {
            tip += "\n" + L10n.format("space.git.main", (main as NSString).abbreviatingWithTildeInPath)
        }
        return SpaceSessionCell.Content.GitRow(text: text, toolTip: tip)
    }

    func hasWaitingSession() -> Bool {
        projects.flatMap(\.sessions).contains { session in
            AttentionQueue.isWaiting(
                state: session.pane?.agents.status?.state, kind: session.pane?.agents.status?.kind,
                attention: session.pane?.agents.notedAttention == true)
        }
    }

    /// Oldest waiting session first. A started session that is off the grid is included.
    func waitingSessionIDs() -> [UUID] {
        let waiting = projects.flatMap(\.sessions).filter { session in
            AttentionQueue.isWaiting(
                state: session.pane?.agents.status?.state, kind: session.pane?.agents.status?.kind,
                attention: session.pane?.agents.notedAttention == true)
        }.map(\.id)
        var priorities: [UUID: Int] = [:]
        for session in projects.flatMap(\.sessions) {
            switch session.pane?.agents.status?.kind {
            case .auth: priorities[session.id] = 0
            case .permission: priorities[session.id] = 1
            case .question: priorities[session.id] = 2
            case nil: break
            }
        }
        return attentionQueue.sync(waiting: waiting, priorities: priorities)
    }

    func jumpToNextWaiting() {
        guard isActive else { return }
        let ordered = waitingSessionIDs()
        guard attentionQueue.deferHead(of: ordered) != nil, let head = ordered.first,
              let (_, session) = session(withID: head) else { return }
        show(session)
        refreshNow()
    }

    private func updateAttentionBadge(ordered: [UUID]) {
        let window = host?.toolbarWindow
        AgentDirectory.noteSpaceWaiting(
            count: ordered.count, active: isActive,
            windowIsKey: window?.isKeyWindow == true && NSApp.isActive)
    }

    /// The project names the window, with its folder as the proxy icon.
    func applyWindowTitle() {
        guard isActive, let window = host?.toolbarWindow else { return }
        let title = selectedProject?.name ?? L10n.text("space.title")
        if window.title != title { window.title = title }
        if window.representedURL != selectedProject?.url { window.representedURL = selectedProject?.url }
        (window.windowController as? TerminalWindowController)?.refreshTabTitle()
    }

    func configurationChanged() {
        guard isActive else { return }
        // A lower `space-panel-limit` takes the least recently used panels
        // off screen; their sessions keep running.
        if let project = selectedProject {
            while project.shown.count > panelLimit,
                  let oldest = SpaceGrid.leastRecentlyUsed(
                      project.shown, recency: { $0.lastUsed }, protected: focusedSession) {
                hide(oldest)
            }
        }
        scheduleRefresh()
    }
}
