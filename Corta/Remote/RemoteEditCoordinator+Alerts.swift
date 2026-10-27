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
import Foundation

extension RemoteEditCoordinator.RemoteEditPresenter {
    /// The production presenter: one alert per prompt, acting directly on
    /// the coordinator. Alerts are app-modal (`runModal`) because the
    /// change being asked about belongs to no particular window — the
    /// editor that made it is another application entirely.
    @MainActor
    static func alerter(coordinator: RemoteEditCoordinator) -> Self {
        Self(
            promptUpload: { [weak coordinator] pending in
                let alert = NSAlert()
                alert.messageText = L10n.text("remoteEdit.changed.title")
                alert.informativeText = L10n.format(
                    "remoteEdit.changed.message", SFTPBrowserModel.displayName(pending.copy.remotePath),
                    pending.copy.host)
                alert.addButton(withTitle: L10n.text("remoteEdit.upload"))
                alert.addButton(withTitle: L10n.text("remoteEdit.dismiss"))
                if alert.runModal() == .alertFirstButtonReturn {
                    coordinator?.upload(pending)
                } else {
                    coordinator?.dismissUpload(pending)
                }
            },
            promptConflict: { [weak coordinator] conflict in
                runConflictAlert(conflict, coordinator: coordinator)
            },
            showError: { message in
                let alert = NSAlert()
                alert.messageText = message
                alert.alertStyle = .warning
                alert.runModal()
            },
            confirmConnection: { host, remotePath in
                let alert = NSAlert()
                alert.messageText = L10n.format("remoteEdit.connect.title", host)
                alert.informativeText = L10n.format(
                    "remoteEdit.connect.message", SFTPBrowserModel.displayName(remotePath), host)
                alert.addButton(withTitle: L10n.text("sftp.host.connect"))
                alert.addButton(withTitle: L10n.text("common.cancel"))
                return alert.runModal() == .alertFirstButtonReturn
            })
    }

    /// The conflict alert: upload anyway, download again (not for a deleted
    /// remote file), save the local copy elsewhere, or leave it.
    private static func runConflictAlert(
        _ conflict: RemoteEditCoordinator.UploadConflict, coordinator: RemoteEditCoordinator?
    ) {
        let alert = NSAlert()
        alert.messageText = L10n.text("remoteEdit.conflict.title")
        alert.informativeText =
            conflict.remoteDeleted
            ? L10n.format(
                "remoteEdit.conflict.deletedMessage",
                SFTPBrowserModel.displayName(conflict.copy.remotePath), conflict.copy.host,
                conflict.atDownloadDescription)
            : L10n.format(
                "remoteEdit.conflict.message",
                SFTPBrowserModel.displayName(conflict.copy.remotePath), conflict.copy.host,
                conflict.atDownloadDescription, conflict.remoteDescription)
        alert.addButton(withTitle: L10n.text("remoteEdit.conflict.uploadAnyway"))
        let redownload = alert.addButton(
            withTitle: L10n.text("remoteEdit.conflict.redownload"))
        redownload.isEnabled = !conflict.remoteDeleted
        alert.addButton(withTitle: L10n.text("remoteEdit.conflict.saveCopy"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            coordinator?.resolveConflict(conflict.id, choice: .uploadAnyway)
        case .alertSecondButtonReturn:
            coordinator?.resolveConflict(conflict.id, choice: .redownload)
        case .alertThirdButtonReturn:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = SFTPBrowserModel.localFileName(
                (conflict.copy.remotePath as NSString).lastPathComponent)
            guard panel.runModal() == .OK, let url = panel.url else {
                coordinator?.resolveConflict(conflict.id, choice: .dismiss)
                return
            }
            coordinator?.resolveConflict(conflict.id, choice: .saveCopyElsewhere(url))
        default:
            coordinator?.resolveConflict(conflict.id, choice: .dismiss)
        }
    }

}
