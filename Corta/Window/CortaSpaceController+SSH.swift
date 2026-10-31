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
    /// Ordinary removal forgets only the local record, never the remote process.
    func confirmRetainedRemoval(_ sessions: [SpaceSession], completion: @escaping () -> Void) {
        let names = Self.retainedRemovalNames(sessions)
        guard !names.isEmpty else { completion(); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("space.ssh.remove.title")
        alert.informativeText = L10n.text("space.ssh.remove.detail") + "\n\n" + names.map {
            "tmux kill-session -t '=\($0)'"
        }.joined(separator: "\n")
        alert.addButton(withTitle: L10n.text("space.ssh.remove.keep"))
        alert.addButton(withTitle: L10n.text("space.ssh.kill.button"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let commands = names.map { "tmux kill-session -t '=\($0)'" }.joined(separator: "\n")
        let copy = SpaceCopyCommandButton(commands: commands)
        alert.accessoryView = copy
        alert.buttons.forEach { $0.bezelStyle = .glass }
        presentAlert(alert, alertWindow()) { [weak self] result in
            if result == .alertFirstButtonReturn { completion() }
            if result == .alertSecondButtonReturn {
                for session in sessions where session.record.retainSSH == true {
                    if let target = session.record.ssh {
                        self?.launchTermination(target: target, command: RemoteTmux(id: session.id).killCommand)
                    }
                }
                completion()
            }
        }
    }

    /// A fragmented start/failure pair must not persist a successful attachment.
    func noteTmuxResult(_ report: RemoteTmux.Report, session: SpaceSession, pane: ViewController) {
        refreshNow()
        scheduleSave()
        guard report.established, let terminal = pane.session else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self, weak session, weak pane] in
            guard let self, let session, pane?.session === terminal,
                  terminal.remoteTmuxReport?.established == true else { return }
            session.record.tmuxEstablished = true
            self.scheduleSave()
        }
    }

    /// Current names plus any `corta-<UUID>` replaced when a duplicate was repaired.
    static func retainedRemovalNames(_ sessions: [SpaceSession]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for session in sessions where session.record.retainSSH == true {
            let candidates = [RemoteTmux(id: session.id).sessionName] + (session.record.supersededTmuxNames ?? [])
            for name in candidates {
                guard let clean = SpaceSessionRecord.canonicalTmuxSessionName(name), seen.insert(clean).inserted
                else { continue }
                names.append(clean)
            }
        }
        return names
    }

    /// A sheet on this window when it can take one, otherwise any visible window.
    /// `nil` is the app-modal fallback inside `NSAlert.present`.
    func alertWindow() -> NSWindow? {
        let preferred = [host?.toolbarWindow, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        if let window = preferred.first(where: NSAlert.canPresentSheet(on:)) { return window }
        if let window = preferred.first(where: { $0.isVisible && !($0 is NSPanel) }) { return window }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && NSAlert.canPresentSheet(on: $0) }
    }

    /// A separate explicit command, with authentication and the result visible
    /// in a terminal window. No shell text from disk or terminal output is used.
    func endRemoteSession(_ session: SpaceSession) {
        guard session.record.retainSSH == true, let target = session.record.ssh else { return }
        let tmux = RemoteTmux(id: session.id)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("space.ssh.kill.title")
        alert.informativeText = target.displayName + "\n" + tmux.sessionName + "\n\n"
            + L10n.text("space.ssh.kill.detail")
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.addButton(withTitle: L10n.text("space.ssh.kill.button"))
        alert.buttons.forEach { $0.bezelStyle = .glass }
        presentAlert(alert, alertWindow()) { result in
            guard result == .alertSecondButtonReturn else { return }
            self.launchTermination(target: target, command: tmux.killCommand)
        }
    }
    private func launchTermination(target: SSHTarget, command: String) {
        if let launchRemoteTermination { launchRemoteTermination(target, command); return }
        var preset = SSHDestination.preset(for: target)
        preset.arguments = target.sshOptions + ["-t", "--", target.host, command]
        (NSApp.delegate as? AppDelegate)?.launchPreset(preset, inNewWindow: true)
    }

}

/// Visible even when tmux clears the screen; also readable before the project starts.
struct SpaceSSHStatus {
    let title: String
    let detail: String

    init(session: SpaceSession) {
        let status = Self(report: session.pane?.remote.tmuxReport,
                          previouslyEstablished: session.pane?.preset?.tmuxPreviouslyEstablished
                            ?? (session.record.tmuxEstablished == true))
        title = session.pane?.session?.pty.exitStatus == nil ? status.title : L10n.text("space.state.ended")
        detail = status.detail
    }

    init(report: RemoteTmux.Report?, previouslyEstablished: Bool) {
        let key: String
        if let status = report?.failureStatus {
            key = "failed"
            detail = L10n.format("space.ssh.failed.detail", status) + "\n" + (report?.reason ?? "")
        } else if report?.outcome == .missing {
            key = "missing"
            detail = L10n.text("space.ssh.missing.detail")
        } else if report?.outcome == .new, previouslyEstablished {
            key = "replaced"
            detail = L10n.text("space.ssh.replaced.detail")
        } else if report?.established == true {
            key = "ready"
            detail = L10n.text("space.ssh.ready.detail")
        } else {
            key = previouslyEstablished ? "attaching" : "starting"
            detail = L10n.text("space.ssh.pending.detail")
        }
        title = L10n.text("space.ssh." + key)
    }
}

private final class SpaceCopyCommandButton: NSButton {
    private let commands: String
    init(commands: String) {
        self.commands = commands
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        title = L10n.text("space.ssh.copyKill")
        bezelStyle = .rounded
        target = self
        action = #selector(copyCommands)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func copyCommands() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }
}
