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
    private var processRefresh: DispatchWorkItem?

    init(host: ViewController) { self.host = host }

    var visible: Bool {
        guard let host, let window = host.view.window else { return false }
        return NSApp.isActive && window.occlusionState.contains(.visible)
            && !host.view.isHiddenOrHasHiddenAncestor
            && (window.tabGroup.map { $0.selectedWindow === window } ?? true)
    }

    func reset() {
        processRefresh?.cancel(); processRefresh = nil
        status = nil; progress = nil; fallback = nil; fallbackProcess = nil
        lastProcessRead = 0; sawSignals = false; sessionHasExited = false
        AgentDirectory.refresh()
    }

    func readOutput() {
        guard !sessionHasExited, let host, let session = host.session else { return }
        let configuration = ConfigurationStore.shared.configuration
        let reported = session.programStatuses
        sawSignals = sawSignals || !reported.isEmpty
        let blocked = session.takeBlockedStatus()
        let notice = session.takeDesktopNotification()
        host.taskNotifier.setProgramBlocked(reported.values.contains { $0.state == .blocked })
        let oldStatus = status
        let oldProgress = progress
        if configuration.agentStatus {
            refreshFallback(session: session, hasReportedStatus: !reported.isEmpty)
            status = reported.values.max { $0.urgency < $1.urgency }
                ?? (sawSignals ? nil : fallback)
            progress = session.programProgress
            if progress == nil, let value = status?.progress {
                progress = ProgramProgress(state: .normal, value: value)
            }
        } else { status = nil; progress = nil }
        if let blocked, !visible {
            host.taskNotifier.noteProgramAttention(kind: blocked, in: host.view.window)
        }
        if let notice {
            host.taskNotifier.noteProgramNotification(notice, visible: visible,
                focused: NSApp.isActive && host.view.window?.isKeyWindow == true && host.isFocusedPane,
                in: host.view.window)
        }
        if oldStatus != status || oldProgress != progress { AgentDirectory.refresh() }
    }

    private func refreshFallback(session: TerminalSession, hasReportedStatus: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Reuse the title's syscall path and cadence, including one trailing
        // read for a fast process/prompt transition. Never periodic polling.
        if now - lastProcessRead >= 0.4 {
            processRefresh?.cancel(); processRefresh = nil
            lastProcessRead = now
            let process = session.activeProcessName ?? ""
            let configured = ConfigurationStore.shared.configuration.agentProcesses.split(separator: ",").map(String.init)
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
        if session.hasShellIntegration, !session.isCommandRunning, fallbackProcess == nil {
            fallback?.state = session.commandRecords.lastCompleted?.didFail == true ? .error : .idle
        }
    }

    func bell() {
        guard ConfigurationStore.shared.configuration.agentStatus,
              !visible, status != nil else { return }
        host?.taskNotifier.noteProgramAttention(kind: nil, in: host?.view.window)
    }

    func exited(success: Bool) {
        // The final OSC can precede EOF by less than the coalescing delay.
        // Read it before sealing the session against late UI callbacks.
        readOutput()
        sessionHasExited = true
        processRefresh?.cancel(); processRefresh = nil
        guard status != nil else { return }
        // A clean process exit is a session end, not proof that its last
        // task succeeded. Preserve a reported completion or failure.
        if !success { status?.state = .error }
        else if status?.state != .done && status?.state != .error { status?.state = .idle }
        status?.kind = nil
        status?.progress = nil; progress = nil
        AgentDirectory.refresh()
    }
}
