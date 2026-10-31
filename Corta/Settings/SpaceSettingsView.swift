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

extension SettingsView {
    var spacePage: some View {
        Form {
            Section(L10n.text("settings.section.space")) {
                Toggle(L10n.text("settings.label.agentMessages"), isOn: bind(\.agentMessages))
                    .help(L10n.text("settings.help.agentMessages"))
                Toggle(L10n.text("settings.label.spaceAttentionBadge"), isOn: bind(\.spaceAttentionBadge))
                Toggle(L10n.text("settings.label.waitingAutoAdvance"), isOn: bind(\.waitingQueueAutoAdvance))
            }
            SpaceTemplatesSettings()
        }
    }
}

private struct SpaceTemplatesSettings: View {
    @State private var file = SpaceTemplateFile.load(from: SpaceTemplateFile.url)
    @State private var details: String?
    @State private var error: String?

    var body: some View {
        Section(L10n.text("space.template.manage")) {
            if file.templates.isEmpty { Text(L10n.text("space.template.empty")).foregroundStyle(.secondary) }
            ForEach(file.templates, id: \.name) { template in
                TemplateSettingsRow(template: template) { name in
                    guard let name = AgentMemberRecord.cleanRole(name),
                          !file.templates.contains(where: { $0.name == name && $0.name != template.name }),
                          let index = file.templates.firstIndex(where: { $0.name == template.name }) else {
                        error = L10n.text("space.template.invalidName")
                        return
                    }
                    file.templates[index].name = name
                    save()
                } show: {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    details = (try? encoder.encode(template)).map { String(decoding: $0, as: UTF8.self) }
                } delete: {
                    file.templates.removeAll { $0.name == template.name }
                    save()
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            VStack(alignment: .trailing) {
                ScrollView { Text(details ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                Button(L10n.text("common.close")) { details = nil }.keyboardShortcut(.cancelAction)
            }.padding().frame(minWidth: 500, minHeight: 360)
        }
    }

    private func save() {
        do { try file.save(to: SpaceTemplateFile.url); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct TemplateSettingsRow: View {
    let template: SpaceTemplate
    let rename: (String) -> Void
    let show: () -> Void
    let delete: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField(L10n.text("space.template.renameTo"), text: $name)
                .onAppear { name = template.name }.onSubmit { rename(name) }
            HStack {
                Button(L10n.text("space.template.rename")) { rename(name) }
                Button(L10n.text("space.template.show"), action: show)
                Spacer()
                Button(L10n.text("space.template.delete"), role: .destructive, action: delete)
            }
        }
    }
}
