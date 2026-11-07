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
import Synchronization

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
/// that. A re-download lands beside the local copy and replaces it
/// atomically once complete, unless the copy was saved again meanwhile.
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
        var contentDigest: String?
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
    private var activeClientUses: [ObjectIdentifier: Int] = [:]
    private var idleClients: [(host: String, timeout: Task<Void, Never>)] = []
    private let maximumIdleClients = 4
    private let clientIdleTime: Duration = .seconds(600)
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
    /// on that host until the app quit. A question on screen does not count
    /// (`ConnectionDeadline`): typing a password must not end the connection.
    private let connectTimeout: Duration
    /// Whether a sign-in question for this host is on screen. A test's own.
    var isAskingHost: (String) -> Bool = { SSHAskpassPrompter.isAsking(host: $0) }
    /// Secures a file a re-download has put in place. A test's own, to fail it.
    lazy var secureFile: (URL) throws -> Void = { [store] in try store.secureCopy(at: $0) }
    /// A connected subsystem can keep ssh alive without answering requests.
    /// Retire that connection so continuations unwind and Upload can retry.
    private let operationTimeout: Duration

    var pendingUploads: [PendingUpload] = []
    var pendingConflicts: [UploadConflict] = []

    /// Each watched copy's source; cancelling one closes its descriptor.
    var watches: [String: DispatchSourceFileSystemObject] = [:]
    /// The SHA-256 of each watched copy as last approved (at download,
    /// upload, or the previously-prompted edit) — the baseline the next
    /// change is measured against.
    var digests: [String: String] = [:]
    struct DigestCheck {
        let id: UUID
        let task: Task<Void, Never>
    }
    /// Keep completion as well as identity: a caller displaced by a newer
    /// check still waits until the replacement has applied its result.
    var digestChecks: [String: DigestCheck] = [:]
    var pendingChecks: [String: DispatchWorkItem] = [:]
    var uploadsInFlight: Set<String> = []
    var approvedSnapshots: [String: URL] = [:]
    nonisolated let recentDigests = Mutex<[URL: (DigestStamp, String)]>([:])

    init(
        store: RemoteEditStore = RemoteEditStore.shared,
        makeClient: ((String) -> any SFTPClient)? = nil,
        opener: (@MainActor (URL, Int, Int?) -> Bool)? = nil,
        presenter: RemoteEditPresenter? = nil,
        connectTimeout: Duration = ConnectionDeadline.timeout,
        operationTimeout: Duration = .seconds(120)
    ) {
        self.store = store
        self.connectTimeout = connectTimeout
        self.operationTimeout = operationTimeout
        self.makeClient =
            makeClient ?? {
                SFTPConnection.forApp(
                    key: $0, maximumDownloadBytes: RemoteEditCoordinator.maximumCopyBytes,
                    restartsManagedDownloadPartials: true)
        }
        self.opener = opener ?? PanePointer.openRemoteFileAt(url:line:column:)
        self.presenter = presenter ?? RemoteEditPresenter(
            promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in })
        // The default presenter needs to call back into the coordinator,
        // which only exists fully-formed at this point.
        if presenter == nil {
            self.presenter = RemoteEditPresenter.alerter(coordinator: self)
        }
        store.onManifestWriteFailure = { [weak self] error in
            self?.presenter.showError(L10n.format("settings.status.writeFailed", error.localizedDescription))
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
        for entry in idleClients { entry.timeout.cancel() }
        for (_, url) in approvedSnapshots { try? FileManager.default.removeItem(at: url) }
    }

}

// MARK: - Open for editing

extension RemoteEditCoordinator {

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
        if digests[copy.id] == nil {
            let baseline = copy.approvedDigest ?? copy.remoteDigest
            let digest = if let baseline { baseline } else { await readDigest(at: store.localURL(for: copy)) }
            if digests[copy.id] == nil { setDigest(digest, for: copy.id) }
        }
        let alreadyWatched = watches[copy.id] != nil
        watch(copy)
        guard opener(store.localURL(for: copy), line, column) else {
            if !alreadyWatched { unwatch(copy.id) }
            return false
        }
        store.recordOpen(copy)
        // A synchronous editor save may precede delivery of the file event.
        await noteLocalWrite(copyID: copy.id)
        return true
    }

    /// The manifest's copy of the file, re-secured, while its local file is
    /// still there; nil otherwise.
    private func existingCopy(host: String, remotePath: String) throws(SFTPError) -> RemoteEditStore.RemoteCopy? {
        guard let copy = store.copy(host: host, remotePath: remotePath),
            FileManager.default.fileExists(atPath: store.localURL(for: copy).path)
        else { return nil }
        do {
            try store.secureCopy(at: store.localURL(for: copy))
        } catch {
            throw .localIOFailed(operation: "secure local copy", code: EACCES)
        }
        return copy
    }

    /// The managed copy, downloading when there is no manifest entry or the
    /// copy's file is gone. A reused copy is *not* re-validated against the
    /// remote here: the upload path's pre-flight `lstat` is where remote
    /// drift is caught, and re-checking on every open would make opening a
    /// file a network round trip for nothing it changes.
    func materialize(host: String, remotePath: String) async throws(SFTPError)
        -> RemoteEditStore.RemoteCopy
    {
        await store.finishMaintenance()
        guard !Task.isCancelled else { throw .cancelled }
        if let error = store.manifestReadError {
            presenter.showError(L10n.format("settings.status.writeFailed", error.localizedDescription))
            throw .cancelled
        }
        if let copy = try existingCopy(host: host, remotePath: remotePath) { return copy }
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
                    "remoteEdit.orphanKept", SFTPBrowserModel.peerText(remotePath),
                    SSHTarget.displayName(forKey: host), keptOrphan.path))
            }
        }
        let copy: RemoteEditStore.RemoteCopy
        do {
            copy = try await withTransferClient(for: host) { client, progress in
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
                policy: .fail, partialDisposition: .remove, progress: progress)
            let digest = await readDigest(at: url)
            let copy = store.recordDownload(
                host: host, remotePath: remotePath,
                remoteSize: attributes.size, remoteMTime: attributes.modificationTime,
                remoteDigest: digest)
            try store.secureCopy(at: url)
            setDigest(digest, for: copy.id)
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
        let shown = SSHTarget.displayName(forKey: host)
        attempt.deadline = Task { [weak self] in
            do {
                try await ConnectionDeadline.wait(timeout) { self?.isAskingHost(shown) ?? false }
            } catch { return }
            self?.abandon(attempt, host: host, error: ConnectionDeadline.failure(after: timeout))
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
        try await withTransferClient(for: host) { client, _ in try await operation(client) }
    }

    func withTransferClient<T>(
        for host: String,
        operation: (any SFTPClient, SFTPTransferEngine.ProgressHandler?) async throws -> T
    ) async throws(SFTPError) -> T {
        let client = try await client(for: host)
        if let idle = idleClients.firstIndex(where: { $0.host == host }) {
            idleClients.remove(at: idle).timeout.cancel()
        }
        let id = ObjectIdentifier(client)
        activeClientUses[id, default: 0] += 1
        defer {
            let remaining = activeClientUses[id, default: 1] - 1
            activeClientUses[id] = remaining == 0 ? nil : remaining
            if remaining == 0, clients[host] === client { parkClient(host: host) }
        }
        let progressCount = Mutex(UInt64(0))
        var timedOut = false
        let timeout = operationTimeout
        let shown = SSHTarget.displayName(forKey: host)
        let deadline = Task { @MainActor [weak self] in
            var lastProgress: UInt64 = 0
            do {
                try await ConnectionDeadline.wait(timeout) {
                    let progress = progressCount.withLock { $0 }
                    let advanced = progress != lastProgress
                    lastProgress = progress
                    return advanced || (self?.isAskingHost(shown) ?? false)
                }
            } catch { return }
            guard !Task.isCancelled else { return }
            timedOut = true
            if self?.clients[host] === client { self?.clients[host] = nil }
            // close resumes in-flight protocol requests, including cleanup.
            client.close()
        }
        defer { deadline.cancel() }
        let timeoutError = SFTPError.transport(.operationTimedOut)
        do {
            let result = try await operation(client) { progress in
                progressCount.withLock { $0 = max($0, progress.completedBytes) }
            }
            guard !timedOut else { throw timeoutError }
            return result
        } catch {
            let error = timedOut ? timeoutError : Self.sftpError(error)
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

    private func parkClient(host: String) {
        let delay = clientIdleTime
        idleClients.append((host, Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.retireIdleClient(host: host)
        }))
        if idleClients.count > maximumIdleClients { retireIdleClient(host: idleClients[0].host) }
    }

    private func retireIdleClient(host: String) {
        guard let index = idleClients.firstIndex(where: { $0.host == host }) else { return }
        idleClients.remove(at: index).timeout.cancel()
        clients.removeValue(forKey: host)?.close()
    }

}

// MARK: - The NSAlert presenter
