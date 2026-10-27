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
import CoreText
import Observation

/// The status rows for shell integration, directory history, recent hosts
/// and notification permission.
extension SettingsModel {
    // MARK: Shell integration

    /// Reflects `ShellIntegration`'s states as an icon,
    /// a sentence and the one action that changes it. Read from disk on
    /// every refresh rather than cached: unlike every other row on this
    /// page, the ground truth here is the shell's startup files — two for
    /// bash — which the user can edit outside Corta at any time.
    func refreshShellIntegrationStatus() {
        let integration = ShellIntegration.current
        switch integration.status() {
        case .notInstalled:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.text("settings.status.shellIntegrationNotInstalled"),
                actionTitle: L10n.text("settings.action.install"))
        case .conflicting(let name):
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.shellIntegrationConflict", name),
                actionTitle: L10n.text("settings.action.installAnyway"))
        case .installed:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.format(
                    "settings.status.shellIntegrationInstalled", integration.displayPath),
                actionTitle: L10n.text("settings.action.remove"))
        case .unreadable(let path):
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.shellIntegrationUnreadable", path))
        case .outdated:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.format(
                    "settings.status.shellIntegrationOutdated", integration.pathsNeedingUpdate),
                actionTitle: L10n.text("settings.action.update"),
                // Removing must not first require writing the new hooks in.
                secondaryActionTitle: L10n.text("settings.action.remove"))
        }
    }

    /// One dispatch point for the row's first button, whichever state put
    /// it there.
    func toggleShellIntegration() {
        let integration = ShellIntegration.current
        switch integration.status() {
        case .notInstalled, .conflicting, .outdated: applyShellIntegration(integration.install())
        case .installed: applyShellIntegration(integration.uninstall())
        case .unreadable: refreshShellIntegrationStatus()
        }
    }

    /// The second button, offered only beside Update.
    func removeShellIntegration() {
        applyShellIntegration(ShellIntegration.current.uninstall())
    }

    /// - Parameter failures: the files that could not be written.
    private func applyShellIntegration(_ failures: [String]) {
        guard failures.isEmpty else {
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format(
                    "settings.status.shellIntegrationWriteFailed", failures.joined(separator: ", ")))
            return
        }
        refreshShellIntegrationStatus()
    }

    // MARK: - Directory history

    /// How many directories `DirectoryHistoryStore` currently
    /// remembers, with a Clear action. Re-read on every refresh, same reason
    /// as `refreshShellIntegrationStatus`: this is app-managed state, not
    /// something this window owns a copy of.
    func refreshDirectoryHistoryStatus() {
        let count = DirectoryHistoryStore.shared.history.entries.count
        directoryHistoryStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.status.directoryHistoryCount", count),
            actionTitle: count > 0 ? L10n.text("settings.action.clear") : nil)
    }

    func clearDirectoryHistory() {
        DirectoryHistoryStore.shared.clear()
        refreshDirectoryHistoryStatus()
    }

    // MARK: - Recent hosts

    /// How many hosts the connect dialogs remember, with a Clear action —
    /// app state like the directory history, re-read on every refresh.
    func refreshRecentHostsStatus() {
        let count = RecentHostsStore.shared.targets.count
        recentHostsStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.recentHosts.count", count),
            actionTitle: count > 0 ? L10n.text("settings.action.clear") : nil)
    }

    func clearRecentHosts() {
        RecentHostsStore.shared.clear()
        refreshRecentHostsStatus()
    }

    // MARK: - Notification permission

    /// Shown only when the setting is on *and* the system has been told not
    /// to deliver — the one combination in which the switch's position is
    /// not the truth.
    func refreshNotificationPermissionNotice() {
        let denied = TaskNotifier.permission == .denied
        guard configuration.notifyOnLongTask && denied else {
            notificationPermissionNotice = RowStatus()
            return
        }
        notificationPermissionNotice = RowStatus(
            kind: .failed, message: L10n.text("settings.status.notificationsDenied"),
            actionTitle: L10n.text("settings.status.openSystemSettings"))
    }

    func openSystemNotificationSettings() {
        TaskNotifier.openSystemNotificationSettings()
    }
}
