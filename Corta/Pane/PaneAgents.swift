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
    weak var host: ViewController?
    private(set) var status: ProgramStatus?
    private(set) var progress: ProgramProgress?
    private var fallback: ProgramStatus?
    private var fallbackProcess: String?
    private var lastProcessRead: TimeInterval = 0
    private var sawSignals = false
    private var sessionHasExited = false
    private var attentionRequest: Int?
    private var processRefresh: DispatchWorkItem?

    init(host: ViewController) { self.host = host }

    var visible: Bool {
        guard let host, let window = host.view.window else { return false }
        return NSApp.isActive && window.occlusionState.contains(.visible)
            && !host.view.isHiddenOrHasHiddenAncestor
            && (window.tabGroup.map { $0.selectedWindow === window } ?? true)
    }

    func reset() {
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
        processRefresh?.cancel(); processRefresh = nil
        status = nil; progress = nil; fallback = nil; fallbackProcess = nil
        lastProcessRead = 0; sawSignals = false; sessionHasExited = false
        AgentDirectory.refresh()
    }

    func readOutput() {
        guard !sessionHasExited, let host, let session = host.session else { return }
        let configuration = ConfigurationStore.shared.configuration
        let signals = session.takeProgramSignals()
        let reported = signals.statuses
        sawSignals = sawSignals || !reported.isEmpty
        let blocked = signals.blocked
        let notice = signals.notification
        if let attention = signals.attention { requestAttention(attention) }
        host.pointer.refreshProgramPointer(shape: signals.pointerShape)
        host.taskNotifier.setProgramBlocked(reported.values.contains { $0.state == .blocked },
            episode: signals.blockedEpisode)
        let oldStatus = status
        let oldProgress = progress
        if configuration.agentStatus {
            updateStatus(session: session, signals: signals)
        } else { status = nil; progress = nil }
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
                focused: NSApp.isActive && host.view.window?.isKeyWindow == true && host.isFocusedPane,
                in: host.view.window)
        }
        if oldStatus != status || oldProgress != progress { AgentDirectory.refresh() }
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
    private func updateStatus(session: TerminalSession, signals: ProgramSignalSnapshot) {
        refreshFallback(session: session, signals: signals)
        status = signals.statuses.values.max { $0.urgency < $1.urgency }
            ?? (sawSignals ? nil : fallback)
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
            let names = ["claude", "claude-code", "codex", "gemini", "aider", "opencode"] + configured
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
              !visible, status != nil else { return }
        host?.taskNotifier.noteProgramAttention(kind: nil, in: host?.view.window)
    }

    func exited(_ exit: ProcessExit) {
        // The final OSC can precede EOF by less than the coalescing delay.
        // Read it before sealing the session against late UI callbacks.
        readOutput()
        sessionHasExited = true
        host?.taskNotifier.setProgramBlocked(false)
        processRefresh?.cancel(); processRefresh = nil
        progress = nil
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
