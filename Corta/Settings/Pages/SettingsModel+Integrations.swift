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
        checkShellIntegration { _ in [] }
    }

    private func applyShellIntegrationStatus(_ status: ShellIntegrationStatus, path: String, needsUpdate: String) {
        switch status {
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
                    "settings.status.shellIntegrationInstalled", path),
                actionTitle: L10n.text("settings.action.remove"))
        case .unreadable(let path):
            shellIntegrationStatus = RowStatus(
                kind: .failed,
                message: L10n.format("settings.status.shellIntegrationUnreadable", path))
        case .outdated:
            shellIntegrationStatus = RowStatus(
                kind: .adjusted,
                message: L10n.format(
                    "settings.status.shellIntegrationOutdated", needsUpdate),
                actionTitle: L10n.text("settings.action.update"),
                // Removing must not first require writing the new hooks in.
                secondaryActionTitle: L10n.text("settings.action.remove"))
        }
    }

    /// One dispatch point for the row's first button, whichever state put
    /// it there.
    func toggleShellIntegration() {
        checkShellIntegration { integration in
            switch integration.status() {
            case .notInstalled, .conflicting, .outdated: integration.install()
            case .installed: integration.uninstall()
            case .unreadable: []
            }
        }
    }

    /// The second button, offered only beside Update.
    func removeShellIntegration() {
        checkShellIntegration { $0.uninstall() }
    }

    private func checkShellIntegration(_ action: @escaping @Sendable (ShellIntegration) -> [String]) {
        guard !isCheckingShellIntegration else { return }
        isCheckingShellIntegration = true
        PathProbe.run { [weak self] in
            let integration = ShellIntegration.current
            let failures = action(integration)
            let status = integration.status()
            let path = integration.displayPath
            let needsUpdate = status == .outdated ? integration.pathsNeedingUpdate : ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCheckingShellIntegration = false
                if failures.isEmpty {
                    self.applyShellIntegrationStatus(status, path: path, needsUpdate: needsUpdate)
                } else {
                    self.shellIntegrationStatus = RowStatus(
                        kind: .failed,
                        message: L10n.format(
                            "settings.status.shellIntegrationWriteFailed", failures.joined(separator: ", ")))
                }
            }
        }
    }

    // MARK: - Dropped copies

    /// The disk the copies of dropped files take, measured off the main actor:
    /// a copy can hold any number of files. The newest request wins.
    func refreshDroppedCopiesStatus() {
        droppedCopiesGeneration += 1
        let generation = droppedCopiesGeneration
        droppedCopiesStatus = RowStatus(kind: .none, message: L10n.text("settings.status.droppedCopiesMeasuring"))
        Task.detached(priority: .utility) { [weak self] in
            let bytes = FileDropStorage.usage()
            await self?.showDroppedCopies(bytes: bytes, generation: generation)
        }
    }

    private func showDroppedCopies(bytes: Int64, generation: Int) {
        guard generation == droppedCopiesGeneration else { return }
        droppedCopiesStatus = bytes > 0
            ? RowStatus(kind: .adjusted, message: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                actionTitle: L10n.text("settings.action.cleanNow"))
            : RowStatus(kind: .none, message: L10n.text("settings.status.droppedCopiesNone"))
    }

    /// After the confirmation the page asks for.
    func cleanDroppedCopies() {
        droppedCopiesGeneration += 1
        let generation = droppedCopiesGeneration
        droppedCopiesStatus = RowStatus(kind: .none, message: L10n.text("settings.status.droppedCopiesMeasuring"))
        Task.detached(priority: .utility) { [weak self] in
            FileDropStorage.removeUnpinned()
            let bytes = FileDropStorage.usage()
            await self?.showDroppedCopies(bytes: bytes, generation: generation)
        }
    }

    // MARK: - Directory history

    /// How many directories `DirectoryHistoryStore` currently
    /// remembers, with a Clear action. Re-read on every refresh, same reason
    /// as `refreshShellIntegrationStatus`: this is app-managed state, not
    /// something this window owns a copy of.
    func refreshDirectoryHistoryStatus() {
        let store = DirectoryHistoryStore.shared
        let count = store.history.entries.count
        if let error = store.persistenceError {
            directoryHistoryStatus = RowStatus(
                kind: .failed, message: L10n.format("settings.status.writeFailed", error.localizedDescription),
                actionTitle: count > 0 && !store.isClearing ? L10n.text("settings.action.clear") : nil)
            return
        }
        directoryHistoryStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.status.directoryHistoryCount", count),
            actionTitle: count > 0 && !store.isClearing ? L10n.text("settings.action.clear") : nil)
    }

    func clearDirectoryHistory() {
        Task { [weak self] in
            let store = DirectoryHistoryStore.shared
            guard !store.isClearing else { return }
            self?.directoryHistoryStatus.actionTitle = nil
            await store.clear()
            self?.refreshDirectoryHistoryStatus()
        }
    }

    // MARK: - Recent hosts

    /// How many hosts the connect dialogs remember, with a Clear action —
    /// app state like the directory history, re-read on every refresh.
    func refreshRecentHostsStatus() {
        let store = RecentHostsStore.shared
        let count = store.targets.count
        if let error = store.persistenceError {
            recentHostsStatus = RowStatus(
                kind: .failed, message: L10n.format("settings.status.writeFailed", error.localizedDescription),
                actionTitle: count > 0 && !store.isClearing ? L10n.text("settings.action.clear") : nil)
            return
        }
        recentHostsStatus = RowStatus(
            kind: .adjusted, message: L10n.format("settings.recentHosts.count", count),
            actionTitle: count > 0 && !store.isClearing ? L10n.text("settings.action.clear") : nil)
    }

    func clearRecentHosts() {
        Task { [weak self] in
            let store = RecentHostsStore.shared
            guard !store.isClearing else { return }
            self?.recentHostsStatus.actionTitle = nil
            await store.clear()
            self?.refreshRecentHostsStatus()
        }
    }

    // MARK: - Notification permission

    /// Shown only when the setting is on *and* the system has been told not
    /// to deliver — the one combination in which the switch's position is
    /// not the truth.
    func refreshNotificationPermissionNotice() {
        let denied = TaskNotifier.permission == .denied
        guard denied, configuration.notifyOnLongTask || configuration.notifyFromPrograms else {
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
