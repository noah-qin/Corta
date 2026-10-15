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
import CortaTerminal
import Foundation

/// Remote editing — the orchestration: download-or-reuse a managed
/// copy, open the editor on it, watch the copy, and require an explicit
/// decision before anything goes back to the remote.
///
/// **Change detection is two-sided and both sides are explicit.**
///
/// - *Local*: each opened copy gets a `DispatchSource` file watch (the
///   `ConfigurationStore` pattern, descriptor re-pointed after an atomic
///   save's rename — never a polling timer). An event whose content still
///   matches the digest approved at download/upload time is ignored —
///   editors touch files without changing them — and a real edit becomes
///   a `PendingUpload` presented as Upload / Dismiss.
///
/// - *Remote*: before any upload, the remote is re-`lstat`ed and compared
///   against the manifest's stamp from download time. Unchanged (size and
///   mtime both match) → upload proceeds. Changed or deleted → a conflict
///   the user resolves explicitly: Upload Anyway / Re-download (discarding
///   local edits — spelled out in the wording) / Save Local Copy
///   Elsewhere / Cancel.
///
/// Uploads run under `.overwrite` with the partial `.remove`d on failure,
/// so an interrupted upload leaves the remote file untouched and no
/// silent `.corta-part` behind — and the failure wording says exactly
/// that. Re-downloads likewise overwrite the local copy atomically.
///
/// All UI goes through the `RemoteEditPresenter` closures, so tests drive
/// the coordinator with fakes and never see an alert; the production
/// presenter is NSAlert-based (`RemoteEditPresenter.alerter`).
@MainActor
final class RemoteEditCoordinator {
    static let shared = RemoteEditCoordinator()

    /// A local edit awaiting a decision.
    nonisolated struct PendingUpload: Identifiable, Equatable {
        let copy: RemoteEditStore.RemoteCopy
        var contentDigest: String? = nil
        var id: String { copy.id }
        /// Display string for the prompt: the remote file this would land on.
        var remoteDisplay: String { "\(SSHTarget.displayName(forKey: copy.host)):\(copy.remotePath)" }
    }

    /// An upload that found the remote changed since download.
    nonisolated struct UploadConflict: Identifiable, Equatable {
        let copy: RemoteEditStore.RemoteCopy
        /// The remote now ("4.2 KB, modified …"), or the deleted wording.
        let remoteDescription: String
        /// What the manifest recorded at download.
        let atDownloadDescription: String
        let remoteDeleted: Bool
        var id: String { copy.id }
    }

    nonisolated enum ConflictChoice {
        case uploadAnyway
        case redownload
        case saveCopyElsewhere(URL)
        case dismiss
    }

    /// Everything the coordinator needs from a UI, as closures.
    nonisolated struct RemoteEditPresenter {
        var promptUpload: @MainActor (PendingUpload) -> Void
        var promptConflict: @MainActor (UploadConflict) -> Void
        var showError: @MainActor (String) -> Void
        /// The first connection to a host this run (`RemoteHostConsent`):
        /// the host is the remote shell's report, not the user's typing,
        /// so fetching a file from it is asked — host and path named —
        /// before any process is spawned. `true` means connect.
        var confirmConnection: @MainActor (_ host: String, _ remotePath: String) async -> Bool

        init(
            promptUpload: @escaping @MainActor (PendingUpload) -> Void,
            promptConflict: @escaping @MainActor (UploadConflict) -> Void,
            showError: @escaping @MainActor (String) -> Void,
            confirmConnection: @escaping @MainActor (String, String) async -> Bool = { _, _ in
                true
            }
        ) {
            self.promptUpload = promptUpload
            self.promptConflict = promptConflict
            self.showError = showError
            self.confirmConnection = confirmConnection
        }
    }

    /// The largest remote file a ⌘-click copies for editing. Larger files
    /// are the file browser's, which shows progress and can cancel.
    nonisolated static let maximumCopyBytes: UInt64 = 64 * 1024 * 1024

    let store: RemoteEditStore
    private let makeClient: (String) -> any SFTPClient
    /// Opens the editor on a local path at a line/column — the same
    /// `open-file-command` machinery local file references use
    /// (`PanePointer.openFileAt`), injected so tests see the arguments
    /// rather than launching an editor.
    private let opener: @MainActor (URL, Int, Int?) -> Bool
    var presenter: RemoteEditPresenter

    private var clients: [String: any SFTPClient] = [:]
    /// One connection being made to a host, shared by every operation that
    /// needs that host meanwhile. Each of them waits on a continuation of
    /// its own, so one that is cancelled stops waiting at once; the attempt
    /// itself is abandoned when its last waiter leaves, or at the deadline.
    private final class ConnectionAttempt {
        let id = UUID()
        let client: any SFTPClient
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<any SFTPClient, any Error>] = [:]

        init(client: any SFTPClient) { self.client = client }
    }
    private var connections: [String: ConnectionAttempt] = [:]
    /// How long a connection may take to answer before it is given up:
    /// ssh's own connect, authentication, and SFTP's INIT/VERSION. A server
    /// whose subsystem never answers would otherwise hold every operation
    /// on that host until the app quit.
    private let connectTimeout: Duration

    var pendingUploads: [PendingUpload] = []
    var pendingConflicts: [UploadConflict] = []

    /// Each watched copy's source; cancelling one closes its descriptor.
    private var watches: [String: DispatchSourceFileSystemObject] = [:]
    /// The SHA-256 of each watched copy as last approved (at download,
    /// upload, or the previously-prompted edit) — the baseline the next
    /// change is measured against.
    var digests: [String: String] = [:]
    private var pendingChecks: [String: DispatchWorkItem] = [:]
    var uploadsInFlight: Set<String> = []
    var approvedSnapshots: [String: URL] = [:]

    init(
        store: RemoteEditStore = RemoteEditStore.shared,
        makeClient: ((String) -> any SFTPClient)? = nil,
        opener: (@MainActor (URL, Int, Int?) -> Bool)? = nil,
        presenter: RemoteEditPresenter? = nil,
        connectTimeout: Duration = .seconds(30)
    ) {
        self.store = store
        self.connectTimeout = connectTimeout
        self.makeClient = makeClient ?? {
            SFTPConnection.forApp(key: $0, maximumDownloadBytes: RemoteEditCoordinator.maximumCopyBytes)
        }
        self.opener = opener ?? PanePointer.openRemoteFileAt(url:line:column:)
        self.presenter = presenter ?? RemoteEditPresenter(
            promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in })
        // The default presenter needs to call back into the coordinator,
        // which only exists fully-formed at this point.
        if presenter == nil {
            self.presenter = RemoteEditPresenter.alerter(coordinator: self)
        }
    }

    isolated deinit {
        for source in watches.values { source.cancel() }
        for (_, check) in pendingChecks { check.cancel() }
        for (_, connection) in connections {
            connection.task?.cancel()
            connection.deadline?.cancel()
            connection.client.close()
            for (_, waiter) in connection.waiters { waiter.resume(throwing: SFTPError.cancelled) }
        }
        for (_, client) in clients { client.close() }
        for (_, url) in approvedSnapshots { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Open for editing

    /// Downloads (or reuses) the managed copy of a remote file, records the
    /// open, starts watching, and opens the editor at `line`/`column`.
    /// Returns whether the editor was actually launched. A missing or invalid
    /// editor command refuses remote copies instead of using a file handler.
    @discardableResult
    func open(
        host: String, remotePath: String, line: Int, column: Int?
    ) async throws(SFTPError) -> Bool {
        // A host named by the pane's OSC 7 report is child output; the
        // first connection to it is the user's decision, not the far
        // end's (`RemoteHostConsent`). A reused copy still goes through
        // this: opening it starts a watch whose upload would connect.
        // Nor is a name passed on that could not have been typed.
        // `host` is an `SSHTarget.key`: a reported name already read as one
        // (`PaneRemote.resolve`), or a browser's or connect sheet's target.
        guard SSHTarget(key: host) != nil else {
            throw .protocolViolation("not a host name ssh is given: \(host)")
        }
        if !RemoteHostConsent.isConfirmed(host) {
            guard await presenter.confirmConnection(SSHTarget.displayName(forKey: host), remotePath) else {
                throw .cancelled
            }
            RemoteHostConsent.confirm(host)
        }
        let copy = try await materialize(host: host, remotePath: remotePath)
        let alreadyWatched = watches[copy.id] != nil
        watch(copy)
        guard opener(store.localURL(for: copy), line, column) else {
            if !alreadyWatched { unwatch(copy.id) }
            return false
        }
        store.recordOpen(copy)
        // A synchronous editor save may precede delivery of the file event.
        noteLocalWrite(copyID: copy.id)
        return true
    }

    /// The managed copy, downloading when there is no manifest entry or the
    /// copy's file is gone. A reused copy is *not* re-validated against the
    /// remote here: the upload path's pre-flight `lstat` is where remote
    /// drift is caught, and re-checking on every open would make opening a
    /// file a network round trip for nothing it changes.
    func materialize(host: String, remotePath: String) async throws(SFTPError)
        -> RemoteEditStore.RemoteCopy
    {
        if let copy = store.copy(host: host, remotePath: remotePath),
            FileManager.default.fileExists(atPath: store.localURL(for: copy).path)
        {
            do { try store.secureCopy(at: store.localURL(for: copy)) }
            catch { throw .localIOFailed(operation: "secure local copy", code: EACCES) }
            return copy
        }
        // Records from a newer Corta name copies this build cannot see; its
        // downloads would set them aside and write where they live.
        if store.preservesNewerManifest {
            presenter.showError(L10n.text("remoteEdit.newerManifest"))
            throw .cancelled
        }
        var keptOrphan: URL?
        let tellAboutOrphan = { [presenter] in
            if let keptOrphan {
                presenter.showError(L10n.format(
                    "remoteEdit.orphanKept", remotePath, SSHTarget.displayName(forKey: host), keptOrphan.path))
            }
        }
        let copy: RemoteEditStore.RemoteCopy
        do {
            copy = try await withClient(for: host) { client in
            let attributes = try await client.lstat(path: remotePath)
            let relative = RemoteEditStore.localRelativePath(host: host, remotePath: remotePath)
            let url = store.rootURL.appendingPathComponent(relative)
            // A copy the manifest no longer names — it was lost or unreadable
            // — may hold edits never uploaded. Kept aside, not overwritten,
            // and the download would otherwise refuse the occupied path.
            if FileManager.default.fileExists(atPath: url.path) {
                keptOrphan = try store.setAsideOrphan(at: url)
            }
            try store.secureCopy(at: url)
            try await client.download(
                remotePath: remotePath, to: url,
                policy: .fail, partialDisposition: .remove, progress: nil)
            let copy = store.recordDownload(
                host: host, remotePath: remotePath,
                remoteSize: attributes.size, remoteMTime: attributes.modificationTime,
                remoteDigest: RemoteEditStore.sha256Hex(ofFile: url))
            try store.secureCopy(at: url)
            digests[copy.id] = RemoteEditStore.sha256Hex(ofFile: url)
            return copy
            }
        } catch {
            // Said even when the download failed: the kept copy may hold
            // edits, and the next open would find the path empty.
            tellAboutOrphan()
            throw error
        }
        tellAboutOrphan()
        return copy
    }

    private func client(for host: String) async throws(SFTPError) -> any SFTPClient {
        if let client = clients[host] { return client }
        let attempt = connections[host] ?? startConnection(to: host)
        let waiter = UUID()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: SFTPError.cancelled)
                        return
                    }
                    attempt.waiters[waiter] = continuation
                }
            } onCancel: { [attemptID = attempt.id] in
                Task { @MainActor [weak self] in
                    self?.stopWaiting(waiter, onAttempt: attemptID, host: host)
                }
            }
        } catch {
            throw Self.sftpError(error)
        }
    }

    private func startConnection(to host: String) -> ConnectionAttempt {
        let attempt = ConnectionAttempt(client: makeClient(host))
        connections[host] = attempt
        let client = attempt.client
        attempt.task = Task { [weak self] in
            var failure: SFTPError?
            do {
                _ = try await client.connect()
            } catch {
                failure = Self.sftpError(error)
            }
            self?.finish(attempt, host: host, failure: failure)
        }
        let timeout = connectTimeout
        attempt.deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.abandon(
                attempt, host: host,
                error: .transport(.hostUnreachable(
                    diagnostics: "no SFTP answer within \(timeout.components.seconds) seconds")))
        }
        return attempt
    }

    private func finish(_ attempt: ConnectionAttempt, host: String, failure: SFTPError?) {
        attempt.deadline?.cancel()
        guard connections[host] === attempt else {
            // Abandoned meanwhile: a late success is nobody's connection.
            attempt.client.close()
            return
        }
        connections[host] = nil
        let waiters = attempt.waiters
        attempt.waiters = [:]
        if let failure {
            attempt.client.close()
            for (_, waiter) in waiters { waiter.resume(throwing: failure) }
        } else {
            clients[host] = attempt.client
            for (_, waiter) in waiters { waiter.resume(returning: attempt.client) }
        }
    }

    /// A cancelled operation stops waiting now. The attempt goes on for the
    /// others, and is abandoned when it was the last one waiting.
    private func stopWaiting(_ waiter: UUID, onAttempt attemptID: UUID, host: String) {
        // An attempt that already finished resumed this waiter itself.
        guard let attempt = connections[host], attempt.id == attemptID else { return }
        attempt.waiters.removeValue(forKey: waiter)?.resume(throwing: SFTPError.cancelled)
        if attempt.waiters.isEmpty { abandon(attempt, host: host, error: .cancelled) }
    }

    /// Gives an attempt up: its client is closed, which ends the connect,
    /// and whoever still waits hears `error`. The next operation on the
    /// host starts a fresh attempt.
    private func abandon(_ attempt: ConnectionAttempt, host: String, error: SFTPError) {
        guard connections[host] === attempt else { return }
        connections[host] = nil
        attempt.deadline?.cancel()
        attempt.task?.cancel()
        attempt.client.close()
        let waiters = attempt.waiters
        attempt.waiters = [:]
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
    }

    /// A failed conversation is retired, not replayed. The next explicit
    /// operation reconnects; uploads still require their original decision.
    func withClient<T>(
        for host: String,
        operation: (any SFTPClient) async throws -> T
    ) async throws(SFTPError) -> T {
        let client = try await client(for: host)
        do {
            return try await operation(client)
        } catch {
            let error = Self.sftpError(error)
            switch error {
            case .transport, .protocolViolation:
                if clients[host] === client {
                    clients[host] = nil
                    client.close()
                }
            default: break
            }
            throw error
        }
    }

    // MARK: - Local change detection

    func watch(_ copy: RemoteEditStore.RemoteCopy) {
        unwatch(copy.id)
        let url = store.localURL(for: copy)
        if digests[copy.id] == nil {
            // The content last decided on, when the manifest has it: a copy
            // edited and never uploaded — a failed upload, then a quit — is
            // then a pending edit on the next open, where the copy's current
            // content would have made it the baseline; a dismissed one is not.
            digests[copy.id] =
                copy.approvedDigest ?? copy.remoteDigest ?? RemoteEditStore.sha256Hex(ofFile: url)
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        let id = copy.id
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An editor's save is often several events and, for an atomic
            // save, a rename that retires the inode this descriptor holds —
            // so coalesce briefly, then re-point the watch and compare
            // content (the ConfigurationStore pattern).
            self.pendingChecks[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.repointWatch(copyID: id)
                self?.noteLocalWrite(copyID: id)
            }
            self.pendingChecks[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watches[copy.id] = source
    }

    private func repointWatch(copyID: String) {
        guard pendingChecks[copyID] != nil else { return }
        pendingChecks[copyID] = nil
        guard let copy = store.copies[copyID] else { return }
        watch(copy)
    }

    private func unwatch(_ copyID: String) {
        pendingChecks[copyID]?.cancel()
        pendingChecks[copyID] = nil
        watches[copyID]?.cancel()
        watches[copyID] = nil
    }

    /// The watch handler's payload, separated so tests can drive it
    /// directly: a write whose content matches the approved digest is
    /// noise; anything else is an edit awaiting a decision. Internal, not
    /// private, for exactly that reason.
    func noteLocalWrite(copyID: String) {
        guard let copy = store.copies[copyID] else { return }
        let url = store.localURL(for: copy)
        guard let digest = RemoteEditStore.sha256Hex(ofFile: url) else {
            // The copy was deleted underneath us: stop watching and drop
            // any pending decision about it.
            unwatch(copyID)
            pendingUploads.removeAll { $0.id == copyID }
            return
        }
        guard digest != digests[copyID] else { return }
        // Approve this state as the new baseline: Dismiss means "not this
        // edit", and the next save is measured against this content, not
        // against the download.
        digests[copyID] = digest
        guard !pendingUploads.contains(where: { $0.id == copyID }),
            !pendingConflicts.contains(where: { $0.id == copyID }),
            !uploadsInFlight.contains(copyID)
        else { return }
        let pending = PendingUpload(copy: copy, contentDigest: digest)
        pendingUploads.append(pending)
        presenter.promptUpload(pending)
    }

}

// MARK: - The NSAlert presenter

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
                    "remoteEdit.changed.message", SFTPBrowserModel.displayName(pending.copy.remotePath), pending.copy.host)
                alert.addButton(withTitle: L10n.text("remoteEdit.upload"))
                alert.addButton(withTitle: L10n.text("remoteEdit.dismiss"))
                if alert.runModal() == .alertFirstButtonReturn {
                    coordinator?.upload(pending)
                } else {
                    coordinator?.dismissUpload(pending)
                }
            },
            promptConflict: { [weak coordinator] conflict in
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
}
