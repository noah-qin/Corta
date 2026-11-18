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

struct SSHHostKeyPrompt {
    struct Fingerprint: Equatable {
        var keyType: String
        var value: String
    }

    let asking: SSHAskpass.Asking
    let fingerprint: Fingerprint?
    let isAddressConflict: Bool

    init(_ asking: SSHAskpass.Asking) {
        self.asking = asking
        let lines = asking.prompt.split(separator: "\n")
        isAddressConflict = lines.first?.hasPrefix("Warning: the ") == true
            && lines.first?.contains("differs from the key for the IP address") == true
            && lines.contains { $0.hasPrefix("Offending key for IP in ") }
            && lines.last?.hasSuffix("(yes/no)?") == true
        // Apple adds a period after the fingerprint. OpenSSH also supports
        // FingerprintHash=md5, so keep its colon-separated value intact.
        let fingerprintLine = /([A-Z0-9-]+) key fingerprint is:? ([^\s.]+)\.?/
        let fingerprintValue = /SHA256:[A-Za-z0-9+\/]{43}|MD5:(?:[a-fA-F0-9]{2}:){15}[a-fA-F0-9]{2}/
        fingerprint = lines.lazy.compactMap { line -> Fingerprint? in
            guard let match = line.wholeMatch(of: fingerprintLine),
                  match.2.wholeMatch(of: fingerprintValue) != nil else { return nil }
            return Fingerprint(keyType: String(match.1), value: String(match.2))
        }.first
    }

    var canContinue: Bool { fingerprint != nil || isAddressConflict }

    var title: String {
        L10n.format(asking.isIntermediateStep ? "askpass.hostKey.title.intermediate" : "askpass.hostKey.title",
                    asking.host)
    }

    var source: String {
        asking.isIntermediateStep
            ? L10n.format("askpass.source.intermediate", asking.host) : L10n.text("askpass.source")
    }

    var advice: String {
        if isAddressConflict { return L10n.text("askpass.hostKey.addressConflict") }
        guard fingerprint != nil else { return L10n.text("askpass.hostKey.missing") }
        return asking.isIntermediateStep
            ? L10n.text("askpass.hostKey.verifyIntermediate") : L10n.text("askpass.hostKey.verify")
    }

    var details: String {
        let prompt = asking.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt == "?" ? "" : prompt
    }
}

struct SSHHostKeySheet: View {
    var prompt: SSHHostKeyPrompt
    var finish: (NSApplication.ModalResponse) -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let fingerprint = prompt.fingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("askpass.hostKey.fingerprint"))
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: fingerprint.keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: fingerprint.value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ssh-host-key-fingerprint")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: prompt.advice)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: prompt.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.details.isEmpty {
                if prompt.isAddressConflict {
                    details
                } else {
                    DisclosureGroup(L10n.text("askpass.hostKey.details"), isExpanded: $showsDetails) {
                        details.padding(.top, 6)
                    }
                    .font(.subheadline)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.text("common.cancel")) { finish(.cancel) }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .keyboardShortcut(.cancelAction)
                if prompt.canContinue {
                    Button(L10n.text(prompt.isAddressConflict ? "askpass.continue" : "askpass.hostKey.trust")) {
                        finish(.OK)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .accessibilityIdentifier("ssh-host-key-continue")
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: 34, height: 34)
                .background(Color(nsColor: .systemOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(verbatim: prompt.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 4)
        }
    }

    private var details: some View {
        ScrollView {
            Text(verbatim: prompt.details)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 106)
    }

    static func makePanel(
        _ prompt: SSHHostKeyPrompt,
        finish: @escaping (NSPanel, NSApplication.ModalResponse) -> Void
    ) -> NSPanel {
        let panel = HostKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SSHHostKeySheet(prompt: prompt) { [weak panel] response in
            if let panel { finish(panel, response) }
        })
        hosting.sizingOptions = .preferredContentSize
        panel.contentViewController = hosting
        panel.cancel = { [weak panel] in
            if let panel { finish(panel, .cancel) }
        }
        return panel
    }

    /// Return is always safe, including when the Trust button has keyboard
    /// focus. Space can still activate the explicitly focused button.
    private final class HostKeyPanel: NSPanel {
        var cancel: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            let key = event.charactersIgnoringModifiers
            if modifiers.isEmpty, key == "\r" || key == "\u{3}" {
                cancel?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
