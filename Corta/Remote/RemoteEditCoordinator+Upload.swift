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
import CortaSFTP
import Foundation

extension RemoteEditCoordinator {
    // MARK: - Upload

    /// The prompt's Upload: check the remote before anything is sent.
    func upload(_ pending: PendingUpload) {
        guard uploadsInFlight.insert(pending.id).inserted else { return }
        Task { await prepareUpload(pending) }
    }

    private func prepareUpload(_ pending: PendingUpload) async {
        let copy = pending.copy
        let snapshot = store.approvalsURL.appendingPathComponent(UUID().uuidString)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: snapshot) } }
        do {
            try await Self.makeSnapshot(
                from: store.localURL(for: copy), at: snapshot, rootURL: store.rootURL)
            guard let digest = await readDigest(at: snapshot),
                digest == pending.contentDigest else {
                try? FileManager.default.removeItem(at: snapshot)
                pendingUploads.removeAll { $0.id == copy.id }
                setDigest(nil, for: copy.id)
                uploadsInFlight.remove(copy.id)
                await noteLocalWrite(copyID: copy.id)
                return
            }
            removeSnapshot(copy.id)
            approvedSnapshots[copy.id] = snapshot
            retained = true
            await checkRemoteAndUpload(copy)
        } catch {
            uploadsInFlight.remove(copy.id)
            presenter.showError(SFTPBrowserModel.errorMessage(
                .localIOFailed(operation: "snapshot approved content", code: EIO), host: copy.host))
            askAgain(copy)
        }
    }

    @concurrent nonisolated private static func makeSnapshot(
        from source: URL, at snapshot: URL, rootURL: URL
    ) async throws {
        try RemoteEditStore.secureCopy(at: snapshot, rootURL: rootURL)
        try FileManager.default.copyItem(at: source, to: snapshot)
        try RemoteEditStore.secureCopy(at: snapshot, rootURL: rootURL)
    }

    /// The prompt's Dismiss: not this edit. The copy stays watched, and the
    /// next save prompts again.
    func dismissUpload(_ pending: PendingUpload) {
        guard !uploadsInFlight.contains(pending.id) else { return }
        removeSnapshot(pending.id)
        pendingUploads.removeAll { $0.id == pending.id }
        store.recordApproved(pending.copy, digest: pending.contentDigest)
    }

    private func checkRemoteAndUpload(_ copy: RemoteEditStore.RemoteCopy) async {
        do {
            let current = try await withClient(for: copy.host) { client in
                try await client.lstat(path: copy.remotePath)
            }
            let matchesContent: Bool
            let metadataMatches =
                current.size == copy.remoteSize && current.modificationTime == copy.remoteMTime
            // A copy downloaded before digests were recorded (1.0.x) has no
            // content baseline, and size and time alone miss a same-size
            // rewrite within the second: it takes the conflict decision
            // (docs/SECURITY.md), once — Upload Anyway records a digest.
            if metadataMatches, let baseline = copy.remoteDigest {
                let probe = store.approvalsURL.appendingPathComponent(UUID().uuidString)
                try store.secureCopy(at: probe)
                defer { try? FileManager.default.removeItem(at: probe) }
                _ = try await withClient(for: copy.host) { client in
                    try await client.download(remotePath: copy.remotePath, to: probe,
                        policy: .fail, partialDisposition: .remove, progress: nil)
                }
                matchesContent = await readDigest(at: probe) == baseline
            } else {
                matchesContent = false
            }
            if matchesContent {
                await performUpload(copy)
            } else {
                uploadsInFlight.remove(copy.id)
                presentConflict(copy, remote: current)
            }
        } catch {
            uploadsInFlight.remove(copy.id)
            let error = Self.sftpError(error)
            if case .server(let status) = error, status.code == .noSuchFile {
                presentConflict(copy, remote: nil)
            } else {
                presenter.showError(
                    SFTPBrowserModel.errorMessage(error, host: copy.host))
                askAgain(copy)
            }
        }
    }

    /// After a failed check or upload the decision is still owed: ask it
    /// again. Left pending without a prompt, the edit was stuck — no later
    /// save prompted while it stayed pending, and nothing offered a retry.
    private func askAgain(_ copy: RemoteEditStore.RemoteCopy) {
        removeSnapshot(copy.id)
        // After the failing call has unwound and released its in-flight
        // mark: the production prompt is modal, and an Upload answered inside
        // it would start before that mark was cleared.
        Task { @MainActor [weak self] in
            guard let self,
                let pending = self.pendingUploads.first(where: { $0.id == copy.id }),
                !self.uploadsInFlight.contains(copy.id)
            else { return }
            self.presenter.promptUpload(pending)
        }
    }

    private func presentConflict(
        _ copy: RemoteEditStore.RemoteCopy, remote: SFTPAttributes?
    ) {
        let conflict = UploadConflict(
            copy: copy,
            remoteDescription: remote.map {
                SFTPBrowserModel.describe(
                    size: $0.size,
                    modified: $0.modificationTime.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    })
            } ?? L10n.text("remoteEdit.conflict.deleted"),
            atDownloadDescription: SFTPBrowserModel.describe(
                size: copy.remoteSize,
                modified: copy.remoteMTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }),
            remoteDeleted: remote == nil)
        pendingConflicts.removeAll { $0.id == conflict.id }
        pendingConflicts.append(conflict)
        presenter.promptConflict(conflict)
    }

    /// The conflict sheet's answer. Upload Anyway overwrites the changed
    /// remote (the engine's atomic rename applies here too); Re-download
    /// discards the local edits by overwriting the local copy — the choice
    /// says so, and the copy's editor window still holding the old content
    /// is the editor's own reload question, not Corta's; Save Local Copy
    /// Elsewhere leaves both sides exactly as they are.
    func resolveConflict(_ conflictID: String, choice: ConflictChoice) {
        guard let conflict = pendingConflicts.first(where: { $0.id == conflictID }) else { return }
        let copy = conflict.copy
        guard !uploadsInFlight.contains(copy.id) else { return }
        switch choice {
        case .uploadAnyway:
            uploadsInFlight.insert(copy.id)
            pendingConflicts.removeAll { $0.id == conflictID }
            Task { [weak self] in
                guard let self else { return }
                await self.performUpload(copy)
            }
        case .redownload:
            pendingConflicts.removeAll { $0.id == conflictID }
            removeSnapshot(copy.id)
            Task { [weak self] in await self?.redownload(copy) }
        case .saveCopyElsewhere(let destination):
            uploadsInFlight.insert(copy.id)
            Task { await saveCopyElsewhere(copy, at: destination, conflict: conflict) }
        case .dismiss:
            removeSnapshot(copy.id)
            pendingConflicts.removeAll { $0.id == conflictID }
            pendingUploads.removeAll { $0.id == conflictID }
            store.recordApproved(copy, digest: digests[copy.id])
        }
    }

    private func saveCopyElsewhere(
        _ copy: RemoteEditStore.RemoteCopy, at destination: URL, conflict: UploadConflict
    ) async {
        let digest: String?
        do {
            // The save panel already asked about replacing an existing
            // file — consent to replace it with the copy, not to lose it
            // when the copy fails.
            digest = try await Self.copyReplacingInBackground(store.localURL(for: copy), at: destination)
        } catch {
            uploadsInFlight.remove(copy.id)
            // Said, and the decision asked again: dropped, it told the user
            // nothing; kept silently, it blocked every later upload prompt.
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let code =
                underlying?.code
                ?? (nsError.domain == NSPOSIXErrorDomain ? nsError.code : Int(EIO))
            presenter.showError(SFTPBrowserModel.errorMessage(
                .localIOFailed(operation: "save copy", code: Int32(clamping: code)),
                host: copy.host))
            presenter.promptConflict(conflict)
            return
        }
        uploadsInFlight.remove(copy.id)
        removeSnapshot(copy.id)
        pendingConflicts.removeAll { $0.id == copy.id }
        pendingUploads.removeAll { $0.id == copy.id }
        setDigest(digest, for: copy.id)
        store.recordApproved(copy, digest: digest)
        // A save in the editor while the copy ran is still a new decision.
        await noteLocalWrite(copyID: copy.id)
    }

    @concurrent nonisolated private static func copyReplacingInBackground(
        _ source: URL, at destination: URL
    ) async throws -> String? {
        try copyReplacing(source, at: destination)
        return RemoteEditStore.sha256Hex(ofFile: destination)
    }

    /// Copies `source` to `destination`, replacing a file already there
    /// only once the copy is complete: the copy is made beside the
    /// destination under a name of its own and `rename(2)`d over it, so a
    /// failure — a missing source, a full disk, no permission — leaves the
    /// existing file exactly as it was. The destination being the source
    /// itself is already the requested state.
    nonisolated static func copyReplacing(_ source: URL, at destination: URL) throws {
        var sourceInfo = Darwin.stat()
        var destinationInfo = Darwin.stat()
        if fstatat(AT_FDCWD, source.path, &sourceInfo, 0) == 0,
            fstatat(AT_FDCWD, destination.path, &destinationInfo, 0) == 0,
            sourceInfo.st_dev == destinationInfo.st_dev,
            sourceInfo.st_ino == destinationInfo.st_ino
        {
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).corta-save-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func removeSnapshot(_ id: String) {
        if let url = approvedSnapshots.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func performUpload(
        _ copy: RemoteEditStore.RemoteCopy
    ) async {
        guard let url = approvedSnapshots[copy.id] else { return }
        do {
            // `.overwrite` is the intent (this *is* the remote file being
            // updated); `.remove` means a failed upload leaves no partial
            // next to it — the remote holds either the old file or the new
            // one, never a fragment.
            _ = try await withClient(for: copy.host) { client in
                try await client.upload(
                    from: url, to: copy.remotePath,
                    policy: .overwrite, partialDisposition: .remove, progress: nil)
            }
            let stamp = try? await withClient(for: copy.host) { client in
                try await client.lstat(path: copy.remotePath)
            }
            let digest = await readDigest(at: url)
            store.updateRemoteStamp(
                copy, size: stamp?.size, mtime: stamp?.modificationTime,
                digest: digest)
            setDigest(digest, for: copy.id)
            pendingUploads.removeAll { $0.id == copy.id }
            pendingConflicts.removeAll { $0.id == copy.id }
            removeSnapshot(copy.id)
            uploadsInFlight.remove(copy.id)
            await noteLocalWrite(copyID: copy.id)
        } catch {
            uploadsInFlight.remove(copy.id)
            // The pending entry stays: the decision is still owed. The
            // wording says what is known about the remote: untouched after
            // a refusal, unknown after a lost connection, and split in two
            // when a replacement could not be finished or undone.
            let error = Self.sftpError(error)
            let key: String
            switch error {
            case .replaceIncomplete: key = "remoteEdit.uploadIncomplete"
            case .transport: key = "remoteEdit.uploadUncertain"
            default: key = "remoteEdit.uploadFailed"
            }
            presenter.showError(
                L10n.format(
                    key, copy.remotePath, copy.host,
                    SFTPBrowserModel.errorMessage(error, host: copy.host)))
            askAgain(copy)
        }
    }

    private func redownload(_ copy: RemoteEditStore.RemoteCopy) async {
        do {
            let url = store.localURL(for: copy)
            let attributes = try await withClient(for: copy.host) { client in
                let attributes = try await client.lstat(path: copy.remotePath)
                try await client.download(
                    remotePath: copy.remotePath, to: url,
                    policy: .overwrite, partialDisposition: .remove, progress: nil)
                return attributes
            }
            try store.secureCopy(at: url)
            let digest = await readDigest(at: url)
            store.updateRemoteStamp(
                copy, size: attributes.size, mtime: attributes.modificationTime,
                digest: digest)
            setDigest(digest, for: copy.id)
            pendingUploads.removeAll { $0.id == copy.id }
            // The atomic download replaced the copy's inode; the watch's
            // descriptor points at the old one.
            watch(copy)
        } catch {
            presenter.showError(
                SFTPBrowserModel.errorMessage(Self.sftpError(error), host: copy.host))
        }
    }

    /// The `catch` narrowing helper, shared with the browser model.
    static func sftpError(_ error: any Error) -> SFTPError {
        SFTPBrowserModel.sftpError(error)
    }
}
