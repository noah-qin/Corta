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
        Form {
            Section(L10n.text("settings.section.commands")) {
                ForEach(TerminalCommand.allCases, id: \.self) { command in
                    LabeledContent(command.title) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(
                                value: model.keybindings[command], onChange: { model.setShortcut($0, for: command) })
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

    var windowSection: some View {
        Section(L10n.text("settings.section.window")) {
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

    /// Untitled: it is the whole page, and the page already says its name.
    var quickTerminalSection: some View {
        Section {
            Toggle(
                L10n.text("settings.label.quickTerminalHotkey"),
                isOn: bind(\.quickTerminal)
            )
            .help(L10n.text("settings.help.quickTerminal"))
            LabeledContent(L10n.text("ui.shortcut.global")) {
                ShortcutRecorder(value: model.quickTerminalKey, onChange: model.setQuickTerminalKey)
            }
            // The switch already says "off"; the row is for which key, or
            // why none.
            if model.quickTerminalStatus.kind != .none {
                StatusRowView(status: model.quickTerminalStatus)
            }
            Picker(
                L10n.text("settings.label.quickTerminalPosition"),
                selection: bind(\.quickTerminalPosition)
            ) {
                ForEach(Configuration.QuickTerminalPosition.allCases, id: \.self) { position in
                    Text(L10n.text("settings.quickTerminalPosition.\(position.rawValue)"))
                        .tag(position)
                }
            }
            Picker(
                L10n.text("settings.label.quickTerminalScreen"),
                selection: bind(\.quickTerminalScreen)
            ) {
                ForEach(Configuration.QuickTerminalScreen.allCases, id: \.self) { screen in
                    Text(L10n.text("settings.quickTerminalScreen.\(screen.rawValue)")).tag(screen)
                }
            }
        }
    }

    var notificationsSection: some View {
        Section(L10n.text("settings.section.notifications")) {
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
        Section(L10n.text("settings.section.history")) {
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
