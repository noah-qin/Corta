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
    func noteOutput() {
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
        sidebar.setWaitingCount(ordered.count)
        noteGitDirectories()
        syncAgentBus()
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
        let foreground = observation?.processes.contains { $0.pid == group } == true
        let status = pane.agents.status
        let idle = status?.state == .idle
        let typing = pane.terminalView?.lastUserInput.map { SuspendingClock.now - $0 < .seconds(3) } ?? false
        let member = member(of: session)
        let agent = observation?.processes.first
        let gate = AgentNudgeGate(
            enabled: member?.nudgeEnabled == true,
            foregroundIsAgent: foreground, idle: idle, userIdle: !typing,
            composing: pane.terminalView?.hasMarkedText() == true,
            bracketedPaste: terminal.isBracketedPasteEnabled,
            nudgesThisMinute: AgentHub.shared.bus.nudges(for: member?.id ?? UUID(), now: Date().timeIntervalSinceReferenceDate))
        return AgentWakeSnapshot(
            kind: kind,
            claudeSocket: agent.flatMap { Self.claudeSocket(of: $0.pid) },
            codexExecutable: kind == "codex" ? agent.flatMap { Self.executablePath(of: $0.pid) } : nil,
            codexThread: observation?.conversation.id?.uuidString,
            gate: gate)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Claude publishes the inbox socket in the process environment. Only an absolute path is accepted.
    private static func claudeSocket(of pid: pid_t) -> String? {
        guard let value = ConversationProcess.environmentValue(pid, key: "CLAUDE_CODE_MESSAGING_SOCKET"),
              value.hasPrefix("/"), !value.contains(".."), value.utf8.count < 104 else { return nil }
        return value
    }

    func writeNudge(to sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID)?.session,
              let terminal = session.pane?.session else { return false }
        return terminal.write(AgentEnvelope.nudgeBytes()) == .accepted
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
        return attentionQueue.sync(waiting: waiting)
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
