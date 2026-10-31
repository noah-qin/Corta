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
import SwiftUI

/// A user-entered destination becomes argv for system OpenSSH, never shell text.
nonisolated enum SSHDestination {
    static func preset(for target: SSHTarget, retaining tmux: RemoteTmux? = nil) -> Preset {
        var preset = Preset(name: target.displayName)
        preset.shell = "/usr/bin/ssh"
        preset.arguments = target.sshArguments
        preset.connectTarget = target
        preset.remoteTmux = tmux
        if let tmux { preset.arguments = retainedArguments(for: target, tmux: tmux) }
        return preset
    }

    /// `ssh <preamble> <options> -t -- <host> <lead-in><wrapper>`. The lead-in
    /// and preamble are fixture-only; a saved connection leaves both empty.
    static func retainedArguments(
        for target: SSHTarget, tmux: RemoteTmux, preamble: [String] = [], commandLeadIn: String = "",
        extras: RemoteTmux.Extras = .init()
    ) -> [String] {
        preamble + target.sshOptions + RemoteTmux.forwardArguments(extras)
            + ["-t", "--", target.host, commandLeadIn + tmux.command(extras: extras)]
    }
}

/// What a connect dialog is for: a terminal over SSH, or the file browser
/// over SFTP. One form serves both, so the two read as the same task.
nonisolated enum RemoteConnectMode: Equatable, Sendable {
    case ssh, sftp

    /// The file browser's own host step names itself by this.
    var title: String {
        switch self {
        case .ssh: L10n.text("ui.ssh.title")
        case .sftp: L10n.text("ui.connect.sftp.title")
        }
    }

    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .sftp: "folder"
        }
    }
}

/// The focused pane's own host, offered first: what the toolbar's Files
/// button did in one click, kept one Return away.
struct RemoteConnectPaneFiles {
    /// The host as Corta names it; nil when the pane is remote but no
    /// honest source names it.
    var host: String?
    var open: () -> Void
}

/// The Connect dialog, for a terminal and for files.
///
/// A sheet on the window it was asked from — the toolbar's button, or
/// Settings ▸ Connections — so it reads as part of that window's task; a
/// free-standing panel only when no window is key (the menu, with every
/// window closed). A plain window background either way: Liquid Glass is
/// the control layer floating over content, not a dialog's backdrop.
@MainActor
final class RemoteConnectController: NSWindowController {
    static let shared = RemoteConnectController()
    private let draft = RemoteConnectDraft()
    private var sessionDestination: ((Preset) -> Void)?

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(
            rootView: RemoteConnectSheet(draft: draft) { [weak self] mode, fields in
                self?.connect(mode: mode, fields: fields)
            })
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Below this a sheet is too short to use; it may then pass a tiny
    /// window's edge.
    private static let minimumHeight: CGFloat = 300

    /// - Parameters:
    ///   - mode: the initially selected connection destination.
    ///   - sender: the control or menu item opening the dialog.
    ///   - paneFiles: the focused pane's host, when it is remote.
    ///   - sessionDestination: receives the preset when opening a session in Space.
    func show(
        _ mode: RemoteConnectMode, sender: Any?, paneFiles: RemoteConnectPaneFiles? = nil,
        sessionDestination: ((Preset) -> Void)? = nil
    ) {
        guard let window else { return }
        if window.isVisible {
            (window.sheetParent ?? window).makeKeyAndOrderFront(sender)
            return
        }
        // A fresh dialog each time: a host left over from the last one is a
        // connection nobody asked for.
        self.sessionDestination = sessionDestination
        draft.reset(mode: mode, paneFiles: paneFiles)
        draft.isSpace = sessionDestination != nil
        window.title = L10n.text("ui.connect.title")
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible,
            parent.attachedSheet == nil, !(parent is NSPanel)
        {
            // No taller than the window it hangs from: a small window's
            // sheet ran past its bottom edge. What does not fit scrolls.
            draft.maxHeight = max(Self.minimumHeight, parent.contentLayoutRect.height - 8)
            parent.beginSheet(window)
        } else {
            draft.maxHeight = nil
            window.center()
            showWindow(sender)
            window.makeKeyAndOrderFront(sender)
        }
        NSApp.activate()
    }

    override func close() {
        sessionDestination = nil
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            super.close()
        }
    }

    /// Validated here, at the boundary: a problem keeps the dialog open and
    /// is what it shows. Nil once the dialog may close.
    private func connect(mode: RemoteConnectMode, fields: SSHTargetFields) -> SSHTarget.Problem? {
        if fields.isEmpty, mode == .sftp, let paneFiles = draft.paneFiles {
            close()
            paneFiles.open()
            return nil
        }
        let target: SSHTarget
        switch fields.target {
        case .success(let value): target = value
        case .failure(let problem): return problem
        }
        let retainSSH = draft.isSpace && draft.retainSSH
        let destination = sessionDestination
        close()
        switch mode {
        case .ssh:
            // Recorded once the connection is established, by the pane
            // (`PaneRemote.watchForEstablishedConnection`).
            var preset = SSHDestination.preset(for: target)
            preset.retainSSH = retainSSH
            if let destination { destination(preset) } else {
                (NSApp.delegate as? AppDelegate)?.launchPreset(preset, inNewWindow: true)
            }
        case .sftp:
            // Recorded once connected, by the browser.
            SFTPBrowserController.open(target)
        }
        return nil
    }
}

/// What the dialog holds while it is open, owned by the controller so each
/// showing starts empty.
@MainActor @Observable
final class RemoteConnectDraft {
    var isSpace = false
    var retainSSH = true
    var mode: RemoteConnectMode = .ssh
    var fields = SSHTargetFields()
    var problem: SSHTarget.Problem?
    var paneFiles: RemoteConnectPaneFiles?
    /// The tallest the dialog may be: its parent window's content height
    /// as a sheet, nil as a free-standing panel.
    var maxHeight: CGFloat?
    /// Bumped on reset, so the host field takes focus again.
    var generation = 0

    func reset(mode: RemoteConnectMode, paneFiles: RemoteConnectPaneFiles? = nil) {
        retainSSH = true
        self.mode = mode
        self.paneFiles = paneFiles
        fields = SSHTargetFields()
        problem = nil
        generation += 1
    }
}

/// The dialog's content: the shared form, with the Terminal / Files switch
/// and Cancel.
private struct RemoteConnectSheet: View {
    @Bindable var draft: RemoteConnectDraft
    let connect: (RemoteConnectMode, SSHTargetFields) -> SSHTarget.Problem?

    var body: some View {
        ScrollView {
            RemoteConnectForm(
                mode: draft.mode, modeSelection: $draft.mode, fields: $draft.fields,
                paneFiles: draft.paneFiles,
                retainSSH: draft.isSpace && draft.mode == .ssh ? $draft.retainSSH : nil,
                error: draft.problem.map(RemoteConnectForm.message),
                focusGeneration: draft.generation,
                onCancel: { RemoteConnectController.shared.close() },
                onConnect: { draft.problem = connect(draft.mode, draft.fields) })
                .onChange(of: draft.fields) { draft.problem = nil }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Its content's height, up to the cap; then it scrolls.
        .frame(maxHeight: draft.maxHeight ?? .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
    }
}
