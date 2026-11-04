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

// MARK: - Themes

extension SettingsView {
    var themesPage: some View {
        SettingsPage {
            themePaletteSection(dark: false)
            themePaletteSection(dark: true)
            Text(L10n.text("settings.themes.help"))
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }

    /// One appearance's theme, chosen apart from the other's: a light
    /// Solarized beside a dark Corta is a choice, not a mismatch.
    private func themePaletteSection(dark: Bool) -> some View {
        let customNames = Set(model.configuration.customThemes.map(\.name))
        let builtIn = model.listedThemes.filter { !customNames.contains($0.name) }
        let custom = model.listedThemes.filter { customNames.contains($0.name) }
        let selected = model.configuration.themeName(dark: dark)
        let canEdit = customNames.contains(selected)
        return SettingsSection(
            L10n.text(dark ? "settings.theme.darkMode" : "settings.theme.lightMode"),
            action: SettingsSectionAction(
                title: L10n.text(canEdit ? "theme.edit" : "settings.action.new"),
                symbol: canEdit ? "pencil.circle" : "plus.circle",
                identifier: canEdit ? (dark ? "theme-edit" : "theme-edit-light")
                    : (dark ? "theme-create-dark" : "theme-create"),
                handler: {
                    let source = Theme.named(selected, in: model.configuration) ?? .corta
                    let editor = ThemeEditorModel(source: source, editing: canEdit)
                    editor.isDark = dark
                    editor.selectsForDark = dark
                    themeEditor = editor
                })
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    if let standard = builtIn.first(where: { $0.name == Theme.corta.name }) {
                        themeGroup(L10n.text("settings.theme.default"), themes: [standard], dark: dark)
                        Divider().frame(height: 84).padding(.top, 32)
                    }
                    let others = builtIn.filter { $0.name != Theme.corta.name }
                    if !others.isEmpty { themeGroup(L10n.text("settings.theme.builtIn"), themes: others, dark: dark) }
                    if !custom.isEmpty { themeGroup(L10n.text("settings.theme.custom"), themes: custom, dark: dark) }
                }.padding(3)
            }
        }
    }

    private func themeGroup(_ title: String, themes: [Theme], dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 5)
            HStack(alignment: .top, spacing: 14) {
                ForEach(themes, id: \.name) { theme in
                    ThemePreviewCard(
                        theme: theme, isDark: dark, isSelected: model.configuration.themeName(dark: dark) == theme.name
                    ) {
                        model.setTheme(theme.name, dark: dark)
                    }
                    .accessibilityIdentifier("theme-choice-\(theme.name)\(dark ? "-dark" : "")")
                }
            }
        }
    }
}
