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

import Foundation

extension SettingsView.Category {
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .shortcuts
            && TerminalCommand.allCases.contains(where: { $0.title.localizedStandardContains(query) })
        {
            return true
        }
        return query.isEmpty
            || ([title] + searchKeys.map { L10n.text($0) })
                .contains { $0.localizedStandardContains(query) }
    }

    private var searchKeys: [String] {
        switch self {
        case .general:
            [
                "settings.section.window", "settings.label.newWindow", "settings.label.restoreWindows",
                "settings.label.confirmClose", "settings.section.panes",
                "settings.label.autoBalancePanes", "settings.label.bestFitSplit",
                "settings.section.notificationsAndAgents",
                "settings.label.notifyOnLongTasks", "settings.label.notifyFromPrograms",
                "settings.label.agentStatus", "settings.label.agentProcesses",
                "settings.label.longerThan", "ui.section.updates", "ui.update.auto",
                "ui.update.applications",
            ]
        case .appearance:
            [
                "settings.section.colorScheme", "settings.appearance.followSystem",
                "settings.appearance.light", "settings.appearance.dark", "settings.section.font",
                "settings.label.font", "settings.label.cjkFont", "settings.label.size",
                "settings.label.fontWeight", "settings.label.lineSpacing", "settings.label.fontFallback",
                "settings.label.emojiRendering", "settings.section.cursor", "settings.cursor.block",
                "settings.cursor.bar", "settings.cursor.underline", "settings.label.cursorBlink",
                "status.settings", "status.details", "status.enable", "status.interface",
                "settings.status.items",
            ] + SystemMetrics.Item.allCases.map { "status.item.\($0.rawValue)" }
        case .themes:
            [
                "settings.label.theme", "settings.theme.lightMode", "settings.theme.darkMode",
                "settings.theme.default", "settings.theme.builtIn", "settings.theme.custom",
                "theme.create", "theme.edit", "theme.editor", "settings.themes.baseColors",
                "settings.themes.ansiColors",
            ]
        case .terminal:
            [
                "settings.label.scrollback",
                "ui.history.commands", "settings.label.ambiguousWidth", "settings.label.bell",
                "ui.section.search",
                "ui.search.case", "ui.search.regex", "settings.section.shell",
                "settings.label.historySuggestions",
                "settings.label.directoryCompletion", "settings.label.commandStatusMarks",
                "settings.label.openFileCommand",
                "settings.label.shellIntegration",
            ]
        case .keyboardMouse:
            [
                "inputSource.settings.title", "inputSource.settings.display",
                "inputSource.settings.position",
                "inputSource.color.direct", "inputSource.color.ime", "settings.label.optionAsMeta",
                "settings.label.pasteWarning",
                "settings.label.openLinksWith", "ui.mouse.override", "settings.label.copyOnSelect",
                "settings.label.focusFollowsMouse",
            ]
        case .shortcuts:
            ["settings.section.commands"]
        case .connections:
            [
                "ui.presets.title", "ui.ssh.title", "ui.presets.add", "ui.presets.shell",
                "ui.presets.directory",
                "ui.presets.arguments", "ui.presets.environment",
            ]
        case .privacy:
            [
                "settings.section.clipboard", "settings.label.allowClipboardCopy",
                "command.secureKeyboardEntry",
                "settings.section.history", "settings.label.directoryHistory",
                "settings.label.directoryHistoryClear",
                "settings.label.recentHosts",
                "settings.section.localData", "settings.label.droppedCopies",
            ]
        }
    }
}
