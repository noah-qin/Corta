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
import SwiftUI

/// A user-entered destination becomes argv for system OpenSSH, never shell text.
nonisolated enum SSHDestination {
    static func preset(host: String, port: Int? = nil) -> Preset? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              (port == nil || (1...65535).contains(port!)), host.filter({ $0 == "@" }).count <= 1,
              !host.hasPrefix("@"), !host.hasSuffix("@") else { return nil }
        var preset = Preset(name: host)
        preset.shell = "/usr/bin/ssh"
        preset.arguments = (port.map { ["-p", String($0)] } ?? []) + ["--", host]
        return preset
    }
}

/// What a connect dialog is for: a terminal over SSH, or the file browser
/// over SFTP. One form serves both, so the two read as the same task.
nonisolated enum RemoteConnectMode: Equatable, Sendable {
    case ssh, sftp

    var title: String {
        switch self {
        case .ssh: L10n.text("ui.ssh.title")
        case .sftp: L10n.text("ui.connect.sftp.title")
        }
    }

    /// The same symbols the window toolbar uses for the two buttons.
    var symbol: String {
        switch self {
        case .ssh: "network"
        case .sftp: "folder"
        }
    }
}

/// The Connect dialog, for SSH and for SFTP.
///
/// A sheet on the window it was asked from — the toolbar's buttons, or
/// Settings ▸ Connections — so it reads as part of that window's task; a
/// free-standing panel only when no window is key (the menu, with every
/// window closed). A plain window background either way: Liquid Glass is
/// the control layer floating over content, not a dialog's backdrop.
@MainActor
final class RemoteConnectController: NSWindowController {
    static let shared = RemoteConnectController()
    private let draft = RemoteConnectDraft()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(
            rootView: RemoteConnectSheet(draft: draft) { [weak self] mode, host, port in
                self?.connect(mode: mode, host: host, port: port) ?? false
            })
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) { show(.ssh, sender: sender) }

    func show(_ mode: RemoteConnectMode, sender: Any?) {
        guard let window else { return }
        if window.isVisible {
            (window.sheetParent ?? window).makeKeyAndOrderFront(sender)
            return
        }
        // A fresh dialog each time: a host left over from the last one is a
        // connection nobody asked for.
        draft.reset(mode: mode)
        window.title = mode.title
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible,
            parent.attachedSheet == nil, !(parent is NSPanel)
        {
            parent.beginSheet(window)
        } else {
            window.center()
            showWindow(sender)
            window.makeKeyAndOrderFront(sender)
        }
        NSApp.activate()
    }

    override func close() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            super.close()
        }
    }

    /// Validated again here — the form's check is for the message, this one
    /// is the boundary. Returns whether the dialog may close.
    private func connect(mode: RemoteConnectMode, host: String, port: Int?) -> Bool {
        switch mode {
        case .ssh:
            guard let preset = SSHDestination.preset(host: host, port: port) else { return false }
            close()
            // Recent hosts are names, and picking one connects on port 22 or
            // the alias's own: a connection on a typed port is not offered
            // again, where it would quietly reach a different port.
            if port == nil { RecentHostsStore.shared.record(host) }
            (NSApp.delegate as? AppDelegate)?.launchPreset(preset, inNewWindow: true)
        case .sftp:
            guard SSHDestination.preset(host: host) != nil else { return false }
            close()
            SFTPBrowserController.open(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return true
    }
}

/// What the dialog holds while it is open, owned by the controller so each
/// showing starts empty.
@MainActor @Observable
final class RemoteConnectDraft {
    var mode: RemoteConnectMode = .ssh
    var host = ""
    var port = ""
    var invalid = false
    /// Bumped on reset, so the host field takes focus again.
    var generation = 0

    func reset(mode: RemoteConnectMode) {
        self.mode = mode
        host = ""
        port = ""
        invalid = false
        generation += 1
    }
}

/// The dialog's content: the shared form, with Cancel.
private struct RemoteConnectSheet: View {
    @Bindable var draft: RemoteConnectDraft
    let connect: (RemoteConnectMode, String, Int?) -> Bool

    var body: some View {
        RemoteConnectForm(
            mode: draft.mode, host: $draft.host,
            port: draft.mode == .ssh ? $draft.port : nil,
            error: draft.invalid ? L10n.text(draft.mode == .ssh ? "ui.ssh.invalid" : "ui.connect.invalidHost") : nil,
            focusGeneration: draft.generation,
            onCancel: { RemoteConnectController.shared.close() },
            onConnect: submit)
            .onChange(of: draft.host) { draft.invalid = false }
            .onChange(of: draft.port) { draft.invalid = false }
            .padding(20)
            .frame(width: 460)
    }

    private func submit() {
        let value = draft.port.trimmingCharacters(in: .whitespaces)
        let port = Int(value)
        guard value.isEmpty || port != nil, connect(draft.mode, draft.host, port) else {
            draft.invalid = true
            return
        }
        draft.invalid = false
    }
}

/// The connect form both dialogs and the file browser's own host step use:
/// a heading, the host (and for SSH the port), the hosts it can suggest,
/// what went wrong if anything did, and what the connection relies on.
struct RemoteConnectForm: View {
    let mode: RemoteConnectMode
    @Binding var host: String
    /// SSH only: SFTP's channel is `ssh -s`, which takes its port from the
    /// SSH configuration.
    var port: Binding<String>?
    /// A line above the field — where a prefilled name came from.
    var notice: String?
    var error: String?
    var focusGeneration = 0
    var onCancel: (() -> Void)?
    let onConnect: () -> Void

    @FocusState private var hostFocused: Bool
    @State private var aliases: [String] = []
    @State private var recents: [String] = []
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(mode.title).font(.headline)
            }
            if let notice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField(L10n.text("ui.ssh.host"), text: $host, prompt: Text(verbatim: "user@hostname"))
                    .focused($hostFocused)
                    .onSubmit(onConnect)
                if let port {
                    TextField(L10n.text("ui.ssh.port"), text: port, prompt: Text(verbatim: "22"))
                        .frame(width: 90)
                        .onSubmit(onConnect)
                        .help(L10n.text("ui.ssh.portDefault"))
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            if !visibleRecents.isEmpty || !visibleAliases.isEmpty {
                suggestions
            }
            if let error {
                // Said in words with a symbol, never by colour alone.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let onCancel {
                    Button(L10n.text("common.cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(L10n.text("sftp.host.connect"), action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .onAppear { hostFocused = true }
        .onChange(of: focusGeneration) { hostFocused = true }
        .task(id: focusGeneration) {
            recents = RecentHostsStore.shared.hosts
            // A file read, off the main actor; small, bounded, read-only.
            aliases = await Task.detached(priority: .userInitiated) { SSHConfigHosts.aliases() }.value
        }
    }

    private var help: String {
        switch mode {
        case .ssh: L10n.text("ui.ssh.help")
        case .sftp: L10n.text("ui.sftp.authHelp") + " " + L10n.text("ui.connect.portHint")
        }
    }

    /// What has been typed narrows the list, the way an address field's
    /// suggestions do; a picked name shows every suggestion again.
    private var filter: String {
        let typed = host.trimmingCharacters(in: .whitespaces)
        return typed == picked ? "" : typed
    }

    private var visibleRecents: [String] { Self.matching(recents, filter) }
    private var visibleAliases: [String] {
        Self.matching(aliases.filter { !recents.contains($0) }, filter)
    }

    static func matching(_ names: [String], _ filter: String) -> [String] {
        guard !filter.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var suggestions: some View {
        List(selection: Binding(
            get: { picked },
            set: { name in
                guard let name else { return }
                picked = name
                host = name
            })
        ) {
            if !visibleRecents.isEmpty {
                Section(L10n.text("ui.connect.recent")) {
                    ForEach(visibleRecents, id: \.self) { name in
                        Label(name, systemImage: "clock").tag(name)
                    }
                }
            }
            if !visibleAliases.isEmpty {
                Section(L10n.text("ui.connect.sshConfig")) {
                    ForEach(visibleAliases, id: \.self) { name in
                        Label(name, systemImage: "doc.text").tag(name)
                    }
                }
            }
        }
        // Double-click or Return connects to the row; the menu forgets a
        // recent one.
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first, recents.contains(name) {
                Button(L10n.text("ui.connect.removeRecent")) {
                    RecentHostsStore.shared.remove(name)
                    recents = RecentHostsStore.shared.hosts
                }
            }
        } primaryAction: { names in
            guard let name = names.first else { return }
            picked = name
            host = name
            onConnect()
        }
        .listStyle(.bordered)
        .frame(height: suggestionHeight)
    }

    /// Tall enough for what there is, up to about six rows.
    private var suggestionHeight: CGFloat {
        let rows = visibleRecents.count + visibleAliases.count
        let headers = (visibleRecents.isEmpty ? 0 : 1) + (visibleAliases.isEmpty ? 0 : 1)
        return min(170, CGFloat(rows) * 24 + CGFloat(headers) * 26 + 8)
    }
}

extension AppDelegate {
    @objc func showSSHConnection(_ sender: Any?) { RemoteConnectController.shared.show(.ssh, sender: sender) }
}
