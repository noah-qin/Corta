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

@MainActor
final class SSHConnectionController: NSWindowController {
    static let shared = SSHConnectionController()
    private var accessibilityObserver: Any?
    private init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.text("ui.ssh.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 16
        let hosting = NSHostingView(rootView: SSHConnectionView { [weak self] preset in
            self?.close()
            (NSApp.delegate as? AppDelegate)?.launchPreset(preset, inNewWindow: true)
        })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = hosting
        window.contentView = glass
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        accessibilityObserver = SystemAccessibility.observe { [weak glass] in
            glass?.tintColor = SystemAccessibility.reduceTransparency ? .windowBackgroundColor : nil
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func show(_ sender: Any?) {
        window?.center()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }
}

private struct SSHConnectionView: View {
    let connect: (Preset) -> Void
    @State private var host = ""
    @State private var port = ""
    @State private var invalid = false
    @FocusState private var hostFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("ui.ssh.title"), systemImage: "network").font(.title2.weight(.semibold))
            Form {
                TextField(L10n.text("ui.ssh.host"), text: $host, prompt: Text(verbatim: "user@hostname"))
                    .focused($hostFocused).onSubmit(submit)
                TextField(L10n.text("ui.ssh.port"), text: $port, prompt: Text(L10n.text("ui.ssh.portDefault")))
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            Text(L10n.text("ui.ssh.help")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if invalid { Text(L10n.text("ui.ssh.invalid")).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { SSHConnectionController.shared.close() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("sftp.host.connect"), action: submit)
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).padding(.top, 16).onAppear { hostFocused = true }
    }
    private func submit() {
        let value = port.trimmingCharacters(in: .whitespaces)
        guard value.isEmpty || Int(value) != nil,
              let preset = SSHDestination.preset(host: host, port: Int(value)) else { invalid = true; return }
        invalid = false
        connect(preset)
    }
}

extension AppDelegate {
    @objc func showSSHConnection(_ sender: Any?) { SSHConnectionController.shared.show(sender) }
}
