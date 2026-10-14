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

import SwiftUI

struct PresetSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var editor: PresetDraft?
    @State private var removing: String?

    var body: some View {
        Form {
            Section {
                Text(L10n.text("ui.presets.help")).foregroundStyle(.secondary)
                Button { RemoteConnectController.shared.show(.ssh, sender: nil) } label: {
                    Label(L10n.text("ui.ssh.title"), systemImage: "network")
                }
            }
            Section(L10n.text("ui.presets.title")) {
                if model.presets.isEmpty {
                    Text(L10n.text("ui.presets.empty")).foregroundStyle(.secondary)
                }
                ForEach(model.presets, id: \.name) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name).fontWeight(.medium)
                            Text(AppDelegate.summary(of: preset))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button(L10n.text("ui.presets.open")) {
                            (NSApp.delegate as? AppDelegate)?.launchPreset(preset, inNewWindow: true)
                        }
                        Button(L10n.text("ui.presets.edit")) { editor = PresetDraft(preset: preset, originalName: preset.name) }
                        Button { removing = preset.name } label: { Image(systemName: "trash") }
                            .help(L10n.text("ui.presets.remove"))
                            .accessibilityLabel(L10n.text("ui.presets.remove"))
                    }
                }
                Button { editor = PresetDraft(preset: Preset(name: ""), originalName: nil) } label: {
                    Label(L10n.text("ui.presets.add"), systemImage: "plus")
                }
            }
            Section {
                Text(L10n.text("ui.sftp.authHelp")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editor) { draft in PresetEditor(model: model, draft: draft) }
        .alert(L10n.text("ui.presets.remove"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("common.cancel"), role: .cancel) { removing = nil }
            Button(L10n.text("ui.presets.remove"), role: .destructive) {
                if let removing { model.removePreset(removing) }
                removing = nil
            }
        } message: { Text(L10n.text("ui.presets.removeHelp")) }
    }
}

private struct PresetDraft: Identifiable {
    let id = UUID()
    let preset: Preset
    let originalName: String?
}

private struct PresetEditor: View {
    let model: SettingsModel
    let draft: PresetDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var shell: String
    @State private var directory: String
    @State private var arguments: String
    @State private var environment: String
    @State private var error = false

    init(model: SettingsModel, draft: PresetDraft) {
        self.model = model
        self.draft = draft
        _name = State(initialValue: draft.preset.name)
        _shell = State(initialValue: draft.preset.shell ?? "")
        _directory = State(initialValue: draft.preset.directory ?? "")
        _arguments = State(initialValue: draft.preset.arguments.joined(separator: " "))
        _environment = State(initialValue: draft.preset.environment.keys.sorted().map { "\($0)=\(draft.preset.environment[$0] ?? "")" }.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("ui.presets.edit")).font(.headline)
            Form {
                TextField(L10n.text("ui.presets.name"), text: $name)
                TextField(L10n.text("ui.presets.shell"), text: $shell)
                TextField(L10n.text("ui.presets.arguments"), text: $arguments)
                TextField(L10n.text("ui.presets.directory"), text: $directory)
                LabeledContent(L10n.text("ui.presets.environment")) {
                    TextEditor(text: $environment).font(.system(.caption, design: .monospaced))
                        .frame(height: 80).border(.quaternary)
                        .accessibilityLabel(L10n.text("ui.presets.environment"))
                }
            }
            Text(L10n.text("ui.presets.formatHelp")).font(.caption).foregroundStyle(.secondary)
            if error { Text(L10n.text("ui.presets.invalid")).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("ui.common.save"), action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
    private func save() {
        var preset = Preset(name: name.trimmingCharacters(in: .whitespaces))
        guard SettingsModel.validPresetName(preset.name),
              !shell.contains(where: { $0.isNewline || $0 == "\0" }),
              !directory.contains(where: { $0.isNewline || $0 == "\0" }),
              !arguments.contains(where: { $0.isNewline || $0 == "\0" }) else { error = true; return }
        preset.shell = shell.isEmpty ? nil : shell
        preset.directory = directory.isEmpty ? nil : (directory as NSString).expandingTildeInPath
        preset.arguments = arguments.split(separator: " ").map(String.init)
        for line in environment.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else { error = true; return }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard !key.contains(where: { $0.isWhitespace || $0 == "\0" }), !value.contains("\0") else { error = true; return }
            preset.environment[key] = value
        }
        if model.savePreset(preset, replacing: draft.originalName) { dismiss() } else { error = true }
    }
}
