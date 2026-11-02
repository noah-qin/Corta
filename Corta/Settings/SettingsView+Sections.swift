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

extension SettingsView {
    // MARK: - Shortcuts

    /// Every command's key, in the menu order; written as `bind.` keys.
    var shortcutsPage: some View {
        SettingsPage {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("settings.shortcuts.search"), text: $shortcutSearch)
                    .textFieldStyle(.plain).accessibilityIdentifier("shortcuts-search")
                if !shortcutSearch.isEmpty {
                    Button {
                        shortcutSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("settings.search.clear"))
                }
            }
            .padding(12).background(.quaternary, in: .rect(cornerRadius: 10))
            ForEach(CommandCategory.allCases, id: \.self) { category in
                let commands = TerminalCommand.allCases.filter {
                    $0.category == category
                        && (shortcutSearch.isEmpty || $0.title.localizedStandardContains(shortcutSearch))
                }.sorted { $0.paletteRank < $1.paletteRank }
                if !commands.isEmpty {
                    SettingsSection(category.title) {
                        ForEach(commands, id: \.self) { command in
                            LabeledContent(command.title) {
                                HStack(spacing: 6) {
                                    ShortcutRecorder(
                                        value: model.keybindings[command],
                                        onChange: { model.setShortcut($0, for: command) })
                                    // Only where there is something to restore; the
                                    // slot stays, so the recorders line up.
                                    let isDefault = model.keybindings[command] == command.defaultShortcut
                                    Button {
                                        model.resetShortcut(command)
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.text("ui.shortcut.reset"))
                                    .accessibilityLabel(L10n.text("ui.shortcut.reset"))
                                    .opacity(isDefault ? 0 : 1)
                                    .disabled(isDefault)
                                    .accessibilityHidden(isDefault)
                                }
                            }
                        }
                    }
                }
            }
            if !TerminalCommand.allCases.contains(where: {
                shortcutSearch.isEmpty || $0.title.localizedStandardContains(shortcutSearch)
            }) {
                ContentUnavailableView.search(text: shortcutSearch)
            }
        }
    }

    var windowSection: some View {
        SettingsSection(L10n.text("settings.section.window")) {
            LabeledContent(L10n.text("settings.label.newWindow")) {
                HStack(spacing: 6) {
                    numberField(bind(model.columns, model.setColumns), width: 54)
                    Text(verbatim: "×").foregroundStyle(.secondary)
                    numberField(bind(model.rows, model.setRows), width: 54)
                }
            }
            .help(L10n.text("settings.help.newWindow"))
            Toggle(
                L10n.text("settings.label.restoreWindows"),
                isOn: bind(\.restoreWindows))
        }
    }

    var notificationsSection: some View {
        SettingsSection(L10n.text("settings.section.notifications")) {
            Toggle(
                L10n.text("settings.label.notifyOnLongTasks"),
                isOn: bind(\.notifyOnLongTask)
            )
            .help(L10n.text("settings.help.notifyOnLongTasks"))
            if model.notificationPermissionNotice.kind != .none {
                StatusRowView(
                    status: model.notificationPermissionNotice,
                    action: model.openSystemNotificationSettings)
            }
            LabeledContent(L10n.text("settings.label.longerThan")) {
                HStack(spacing: 6) {
                    numberField(
                        bind(model.notificationThreshold, model.setNotificationThreshold),
                        width: 54)
                    Text(L10n.text("settings.label.seconds")).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.notifyOnLongTask)
        }
    }

    var historySection: some View {
        SettingsSection(L10n.text("settings.section.history")) {
            Toggle(
                L10n.text("settings.label.directoryHistory"),
                isOn: bind(\.directoryHistory)
            )
            .help(L10n.text("settings.help.directoryHistory"))
            LabeledContent(L10n.text("settings.label.directoryHistoryClear")) {
                StatusRowView(
                    status: model.directoryHistoryStatus,
                    action: Self.action(if: model.directoryHistoryStatus.actionTitle != nil) {
                        model.clearDirectoryHistory()
                    })
            }
            // The hosts the connect dialogs offer under Recent.
            LabeledContent(L10n.text("settings.label.recentHosts")) {
                StatusRowView(
                    status: model.recentHostsStatus,
                    action: Self.action(if: model.recentHostsStatus.actionTitle != nil) {
                        model.clearRecentHosts()
                    })
            }
        }
    }
}
