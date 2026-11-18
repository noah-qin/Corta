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
import CortaPOSIX
import Darwin

/// Event-driven pane metadata. Output, prompt return, attention and exit are
/// facts; silence is deliberately not interpreted with a polling timer.
@MainActor
final class PaneAgents {
    weak var host: TerminalPaneViewController?
    private(set) var status: ProgramStatus?
    private(set) var progress: ProgramProgress?
    private var fallback: ProgramStatus?
    private var fallbackProcess: String?
    private var lastProcessRead: TimeInterval = 0
    private var sawSignals = false
    private var waitingEpisode: Int?
    private var sessionHasExited = false
    private var attentionRequest: Int?
    private var processRefresh: DispatchWorkItem?
    /// The reported status is a `blocked` report from a pane whose foreground
    /// program is not a known agent: shown as State unknown, labelled unverified.
    private(set) var statusIsUnverified = false
    /// The program that held the terminal when the latest wait arrived, as
    /// the session recorded it with the bytes. Tests inject one.
    var waitProgram: @MainActor (ProgramSignalSnapshot) -> ForegroundProgram? = { $0.waitProgram }

    init(host: TerminalPaneViewController) { self.host = host }

    var visible: Bool {
        guard let host, let window = host.view.window else { return false }
        return NSApp.isActive && window.occlusionState.contains(.visible)
            && !host.view.isHiddenOrHasHiddenAncestor
    }

    func reset() {
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
        processRefresh?.cancel(); processRefresh = nil
        if let host { AgentDirectory.updateWaiting(host.taskNotifier.paneID, blocked: false) }
        waitingEpisode = nil; statusIsUnverified = false
        status = nil; progress = nil; fallback = nil; fallbackProcess = nil
        lastProcessRead = 0; sawSignals = false; sessionHasExited = false
        AgentDirectory.refresh()
    }

    func readOutput() {
        guard !sessionHasExited, let host, !host.didTeardown, let session = host.session else { return }
        let configuration = ConfigurationStore.shared.configuration
        let signals = session.takeProgramSignals()
        let reported = signals.statuses
        sawSignals = sawSignals || !reported.isEmpty
        let notice = signals.notification
        if let attention = signals.attention { requestAttention(attention) }
        host.pointer.refreshProgramPointer(shape: signals.pointerShape)
        // Any bytes the pane prints can carry a wait: `cat` of a file, a
        // remote host, the body of a `curl`. Only an agent's raises attention.
        let reportsWait = reported.values.contains { $0.state == .blocked }
        let isBlocked = reportsWait && Self.isAgent(waitProgram(signals),
            configured: configuration.agentProcesses)
        let blocked = isBlocked ? signals.blocked : nil
        host.taskNotifier.setProgramBlocked(isBlocked, episode: signals.blockedEpisode)
        // A leave/re-entry can happen between two coalesced UI reads.
        if isBlocked, let waitingEpisode, waitingEpisode != signals.blockedEpisode {
            AgentDirectory.updateWaiting(host.taskNotifier.paneID, blocked: false)
        }
        waitingEpisode = isBlocked ? signals.blockedEpisode : nil
        let queueChanged = AgentDirectory.updateWaiting(host.taskNotifier.paneID, blocked: isBlocked)
        let oldStatus = status
        let oldProgress = progress
        let oldUnverified = statusIsUnverified
        if configuration.agentStatus {
            updateStatus(session: session, signals: signals, unverifiedWait: reportsWait && !isBlocked)
        } else { status = nil; progress = nil; statusIsUnverified = false }
        if let blocked, !visible {
            host.taskNotifier.noteProgramAttention(kind: blocked, in: host.view.window)
        }
        for id in signals.closedNotificationIDs {
            var close = DesktopNotification()
            close.id = id; close.close = true
            host.taskNotifier.noteProgramNotification(close, visible: visible, focused: false, in: host.view.window)
        }
        if let notice {
            host.taskNotifier.noteProgramNotification(notice, visible: visible,
                focused: NSApp.isActive && host.view.window?.isKeyWindow == true && host.holdsWindowFocus,
                in: host.view.window)
        }
        if queueChanged || oldStatus != status || oldProgress != progress || oldUnverified != statusIsUnverified {
            AgentDirectory.refresh()
        }
    }

    static let builtInAgents = ["claude", "claude-code", "codex", "gemini", "aider", "opencode"]
    private static let agentIcons: Set<ProgramIcon> = [.claude, .codex, .gemini, .opencode, .aider]

    /// Whether a wait comes from an agent: a member of the foreground group
    /// when it arrived is a built-in or configured agent by its executable,
    /// or an interpreter running one as a package or an installed command
    /// (npm's Codex is `node …/bin/codex`). A script merely named after an
    /// agent is not one, and neither is `ssh`: a remote pane cannot name the
    /// program that reported. Answering the `?` probe proves nothing, since
    /// the same bytes can send it.
    static func isAgent(_ program: ForegroundProgram?, configured: String) -> Bool {
        guard let program else { return false }
        let names = Set(configured.split(separator: ",").map(String.init))
        return program.members.contains { member in
            if builtInAgents.contains(member.name) || names.contains(member.name) { return true }
            guard let entryPoint = member.entryPoint else {
                return agentIcons.contains(ProgramIcon.identify(member.name))
            }
            if names.contains((entryPoint as NSString).lastPathComponent) { return true }
            let folders = entryPoint.split(separator: "/")
            let installed = folders.contains("node_modules") || ["bin", ".bin"].contains(folders.dropLast().last)
            return installed && agentIcons.contains(ProgramIcon.identify(member.name, entryPoint: entryPoint))
        }
    }

    /// Bounces the Dock icon as the program asked, replacing any earlier
    /// request; only while Corta is in the background.
    private func requestAttention(_ attention: ProgramAttention) {
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
        guard !NSApp.isActive else { return }
        switch attention {
        case .once: attentionRequest = NSApp.requestUserAttention(.informationalRequest)
        case .continuous: attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        case .cancel: break
        }
    }

    /// The most urgent reported status, else the process fallback until a
    /// program has reported once; tab metadata colours it, and its progress
    /// stands in when the program sent none.
    private func updateStatus(session: TerminalSession, signals: ProgramSignalSnapshot, unverifiedWait: Bool) {
        refreshFallback(session: session, signals: signals)
        // An unverified wait stays visible, as no more than State unknown.
        let reported = unverifiedWait ? signals.statuses.mapValues { status in
            guard status.state == .blocked else { return status }
            var unverified = status
            unverified.state = .unknown; unverified.kind = nil
            return unverified
        } : signals.statuses
        status = Self.preferredStatus(reported) ?? (sawSignals ? nil : fallback)
        statusIsUnverified = unverifiedWait && status?.state == .unknown
        if let metadata = signals.tabMetadata {
            if status == nil {
                status = metadata
            } else {
                status?.color = metadata.color
                status?.statusColor = metadata.statusColor
                if status?.title.isEmpty == true { status?.title = metadata.title }
            }
        }
        progress = signals.progress
        if progress == nil, let value = status?.progress {
            progress = ProgramProgress(state: .normal, value: value)
        }
    }

    /// Equal urgency prefers the smallest slot ID (main's empty ID first).
    /// Neither arrival/dictionary order nor kind changes that tie-break.
    nonisolated static func preferredStatus(_ statuses: [String: ProgramStatus]) -> ProgramStatus? {
        statuses.min {
            if $0.value.urgency != $1.value.urgency { return $0.value.urgency > $1.value.urgency }
            return $0.key < $1.key
        }?.value
    }

    private func refreshFallback(session: TerminalSession, signals: ProgramSignalSnapshot) {
        let hasReportedStatus = !signals.statuses.isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        // Reuse the title's syscall path and cadence, including one trailing
        // read for a fast process/prompt transition. Never periodic polling.
        if now - lastProcessRead >= 0.4 {
            processRefresh?.cancel(); processRefresh = nil
            lastProcessRead = now
            let process = session.activeProcessName ?? ""
            let configured = ConfigurationStore.shared.configuration.agentProcesses
                .split(separator: ",").map(String.init)
            let names = Self.builtInAgents + configured
            if names.contains(process) {
                if fallbackProcess != process {
                    fallback = ProgramStatus(state: .unknown, app: process)
                    if !hasReportedStatus { sawSignals = false }
                }
                fallbackProcess = process
            } else if fallbackProcess != nil {
                fallback?.state = .idle
                fallbackProcess = nil
            }
        } else if processRefresh == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.processRefresh = nil
                self.readOutput()
            }
            processRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 - (now - lastProcessRead), execute: work)
        }
        // Output (including prompt redraws), notifications and BEL do not
        // tell us whether an interactive agent is working or has finished.
        if fallback != nil, signals.hasShellIntegration, !signals.isCommandRunning, fallbackProcess == nil {
            let exit = signals.lastExitStatus
            fallback?.state = exit != nil && exit != 0 && exit != 130 ? .error : .idle
        }
    }

    func bell() {
        guard ConfigurationStore.shared.configuration.agentStatus,
              !visible, status != nil, !statusIsUnverified else { return }
        host?.taskNotifier.noteProgramAttention(kind: nil, in: host?.view.window)
    }

    func exited(_ exit: ProcessExit) {
        // The final OSC can precede EOF by less than the coalescing delay.
        // Read it before sealing the session against late UI callbacks.
        readOutput()
        sessionHasExited = true
        if let host { AgentDirectory.updateWaiting(host.taskNotifier.paneID, blocked: false) }
        host?.taskNotifier.setProgramBlocked(false)
        processRefresh?.cancel(); processRefresh = nil
        progress = nil; statusIsUnverified = false
        guard status != nil else { AgentDirectory.refresh(); return }
        // A clean process exit is a session end, not proof that its last
        // task succeeded. Preserve a reported completion or failure.
        if exit == .exited(code: 130) || exit == .signalled(signal: SIGINT) {
            status?.state = .idle
        } else if !exit.isCleanExit {
            status?.state = .error
        } else if status?.state != .done && status?.state != .error {
            status?.state = .idle
        }
        status?.kind = nil
        status?.progress = nil; progress = nil
        AgentDirectory.refresh()
    }
}
