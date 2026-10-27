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

/// The open-file command, validated when the edit is *finished*.
///
/// A text binding writes per keystroke, and the model validates and trims
/// every write: an unclosed `{` was refused and the field snapped back, so
/// `{file}` could not be typed one character at a time, and a trailing
/// space was trimmed away before the next word could follow it — only a
/// paste of the whole command ever got through. The draft lives here until
/// Return or focus loss commits it. An edit that arrives from the config
/// file replaces a draft the user has not touched; a draft they have is
/// theirs until they commit it.
struct OpenFileCommandField: View {
    let model: SettingsModel
    @State private var draft: String
    /// What the file said when the draft last agreed with it; a draft that
    /// differs is the user's unfinished edit.
    @State private var synced: String
    @FocusState private var isEditing: Bool

    init(model: SettingsModel) {
        self.model = model
        _draft = State(initialValue: model.openFileCommand)
        _synced = State(initialValue: model.openFileCommand)
    }

    var body: some View {
        TextField("", text: $draft)
            .labelsHidden()
            .focused($isEditing)
            .onSubmit(commit)
            .onChange(of: isEditing) { _, editing in
                if !editing { commit() }
            }
            .onChange(of: model.openFileCommand) { _, value in
                if draft == synced { draft = value }
                synced = value
            }
            // The page can go away without resigning focus first.
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != synced else { return }
        model.setOpenFileCommand(draft)
        // A refused or trimmed value reads back as what the file holds.
        synced = model.openFileCommand
        draft = synced
    }
}

/// A draft commits only on Return or blur, so partial hex values never reach the file.
struct InputSourceColorField: View {
    let value: String
    let direct: Bool
    let model: SettingsModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(L10n.text(direct ? "inputSource.color.direct" : "inputSource.color.ime")) {
            TextField("", text: $draft, prompt: Text(L10n.text("inputSource.color.system")))
                .labelsHidden()
                .frame(width: 110)
                .focused($focused)
                .accessibilityIdentifier(direct ? "input-source-direct-color" : "input-source-ime-color")
                .onSubmit { commit() }
                .onChange(of: focused) { _, active in if !active { commit() } }
                .onAppear { draft = value }
                .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
                .help(L10n.text("inputSource.color.help"))
        }
    }

    private func commit() {
        model.setInputSourceColor(draft.trimmingCharacters(in: .whitespaces), direct: direct)
        draft = direct ? model.inputSourceDirectColor : model.inputSourceIMEColor
    }
}

struct StatusNetworkInterfaceField: View {
    @Bindable var model: SettingsModel
    @State private var value = "auto"
    var body: some View {
        TextField(L10n.text("status.interface"), text: $value)
            .accessibilityIdentifier("status-network-interface")
            .onSubmit { model.setStatusNetworkInterface(value); value = model.statusNetworkInterface }
            .onAppear { value = model.statusNetworkInterface }
            .onChange(of: model.statusNetworkInterface) { _, name in value = name }
            .help(L10n.text("status.network.help"))
    }
}

/// A font family menu: the default first, then the catalog's families
/// grouped as Apple's or the user's. The font and CJK font pickers.
struct FontFamilyPicker: View {
    let title: String
    let selection: Binding<String>
    /// What the default reads as in the file: `system`, `auto`.
    let defaultTag: String
    let defaultLabel: String
    let entries: [MonospacedFontCatalog.Entry]

    var body: some View {
        Picker(title, selection: selection) {
            Text(defaultLabel).tag(defaultTag)
            // A configured family the list lacks — not installed, not
            // verified, or not measured yet — still shows as chosen.
            if selection.wrappedValue != defaultTag && !entries.contains(where: { $0.name == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            let apple = entries.filter { $0.origin == .apple }
            if !apple.isEmpty {
                Section(L10n.text("settings.font.group.apple")) {
                    ForEach(apple, id: \.name) { Text($0.name).tag($0.name) }
                }
            }
            let user = entries.filter { $0.origin != .apple }
            if !user.isEmpty {
                Section(L10n.text("settings.font.group.user")) {
                    ForEach(user, id: \.name) { Text($0.name).tag($0.name) }
                }
            }
        }
    }
}
