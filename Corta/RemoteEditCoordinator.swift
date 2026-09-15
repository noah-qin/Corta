import AppKit
import CortaTerminal
import Foundation

/// B14, remote editing — the orchestration: download-or-reuse a managed
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
        var id: String { copy.id }
        /// Display string for the prompt: the remote file this would land on.
        var remoteDisplay: String { "\(copy.host):\(copy.remotePath)" }
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

    let store: RemoteEditStore
    private let makeClient: (String) -> any SFTPClient
    /// Opens the editor on a local path at a line/column — the same
    /// `open-file-command` machinery local file references use
    /// (`ViewController.openFileAt`), injected so tests see the arguments
    /// rather than launching an editor.
    private let opener: @MainActor (URL, Int, Int?) -> Bool
    private var presenter: RemoteEditPresenter

    private var clients: [String: any SFTPClient] = [:]

    private(set) var pendingUploads: [PendingUpload] = []
    private(set) var pendingConflicts: [UploadConflict] = []

    private struct Watch {
        var source: DispatchSourceFileSystemObject
        var descriptor: Int32
    }

    private var watches: [String: Watch] = [:]
    /// The SHA-256 of each watched copy as last approved (at download,
    /// upload, or the previously-prompted edit) — the baseline the next
    /// change is measured against.
    private var digests: [String: String] = [:]
    private var pendingChecks: [String: DispatchWorkItem] = [:]
    private var uploadsInFlight: Set<String> = []

    init(
        store: RemoteEditStore = RemoteEditStore.shared,
        makeClient: ((String) -> any SFTPClient)? = nil,
        opener: (@MainActor (URL, Int, Int?) -> Bool)? = nil,
        presenter: RemoteEditPresenter? = nil
    ) {
        self.store = store
        self.makeClient = makeClient ?? { SFTPConnection.forApp(host: $0) }
        self.opener = opener ?? ViewController.openFileAt(url:line:column:)
        self.presenter = presenter ?? RemoteEditPresenter(
            promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in })
        // The default presenter needs to call back into the coordinator,
        // which only exists fully-formed at this point.
        if presenter == nil {
            self.presenter = RemoteEditPresenter.alerter(coordinator: self)
        }
    }

    isolated deinit {
        for (_, watch) in watches { watch.source.cancel() }
        for (_, check) in pendingChecks { check.cancel() }
    }

    // MARK: - Open for editing

    /// Downloads (or reuses) the managed copy of a remote file, records the
    /// open, starts watching, and opens the editor at `line`/`column`.
    /// Returns whether the editor was actually launched — `false` means a
    /// bad `open-file-command`, exactly the local path's failure.
    @discardableResult
    func open(
        host: String, remotePath: String, line: Int, column: Int?
    ) async throws(SFTPError) -> Bool {
        // A host named by the pane's OSC 7 report is child output; the
        // first connection to it is the user's decision, not the far
        // end's (`RemoteHostConsent`). A reused copy still goes through
        // this: opening it starts a watch whose upload would connect.
        if !RemoteHostConsent.isConfirmed(host) {
            guard await presenter.confirmConnection(host, remotePath) else {
                throw .cancelled
            }
            RemoteHostConsent.confirm(host)
        }
        let copy = try await materialize(host: host, remotePath: remotePath)
        store.recordOpen(copy)
        watch(copy)
        return opener(store.localURL(for: copy), line, column)
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
            return copy
        }
        let client = try await client(for: host)
        // lstat first: a missing remote file fails here as the server's own
        // answer, before any local file is created.
        let attributes = try await client.lstat(path: remotePath)
        let relative = RemoteEditStore.localRelativePath(host: host, remotePath: remotePath)
        let url = store.rootURL.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.fail` + `.remove`: a conflicted or interrupted download leaves
        // nothing at the copy path and no partial, so a later open never
        // mistakes a fragment for the file.
        try await client.download(
            remotePath: remotePath, to: url,
            policy: .fail, partialDisposition: .remove, progress: nil)
        let copy = store.recordDownload(
            host: host, remotePath: remotePath,
            remoteSize: attributes.size, remoteMTime: attributes.modificationTime)
        digests[copy.id] = RemoteEditStore.sha256Hex(ofFile: url)
        return copy
    }

    private func client(for host: String) async throws(SFTPError) -> any SFTPClient {
        if let client = clients[host] { return client }
        let client = makeClient(host)
        clients[host] = client
        do {
            try await client.connect()
        } catch {
            clients[host] = nil
            throw error
        }
        return client
    }

    // MARK: - Local change detection

    private func watch(_ copy: RemoteEditStore.RemoteCopy) {
        unwatch(copy.id)
        let url = store.localURL(for: copy)
        if digests[copy.id] == nil {
            digests[copy.id] = RemoteEditStore.sha256Hex(ofFile: url)
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
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
        watches[copy.id] = Watch(source: source, descriptor: descriptor)
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
        watches[copyID]?.source.cancel()
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
        let pending = PendingUpload(copy: copy)
        pendingUploads.append(pending)
        presenter.promptUpload(pending)
    }

    // MARK: - Upload

    /// The prompt's Upload: check the remote before anything is sent.
    func upload(_ pending: PendingUpload) {
        let copy = pending.copy
        guard !uploadsInFlight.contains(copy.id) else { return }
        uploadsInFlight.insert(copy.id)
        Task { await self.checkRemoteAndUpload(copy) }
    }

    /// The prompt's Dismiss: not this edit. The copy stays watched, and the
    /// next save prompts again.
    func dismissUpload(_ pending: PendingUpload) {
        pendingUploads.removeAll { $0.id == pending.id }
    }

    private func checkRemoteAndUpload(_ copy: RemoteEditStore.RemoteCopy) async {
        defer { uploadsInFlight.remove(copy.id) }
        do {
            let client = try await client(for: copy.host)
            let current = try await client.lstat(path: copy.remotePath)
            if current.size == copy.remoteSize,
                current.modificationTime == copy.remoteMTime
            {
                await performUpload(copy, client: client)
            } else {
                presentConflict(copy, remote: current)
            }
        } catch {
            let error = Self.sftpError(error)
            if case .server(let status) = error, status.code == .noSuchFile {
                presentConflict(copy, remote: nil)
            } else {
                presenter.showError(
                    SFTPBrowserModel.errorMessage(error, host: copy.host))
            }
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
        switch choice {
        case .uploadAnyway:
            pendingConflicts.removeAll { $0.id == conflictID }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try await self.client(for: copy.host)
                    await self.performUpload(copy, client: client)
                } catch {
                    self.presenter.showError(
                        SFTPBrowserModel.errorMessage(Self.sftpError(error), host: copy.host))
                }
            }
        case .redownload:
            pendingConflicts.removeAll { $0.id == conflictID }
            Task { [weak self] in await self?.redownload(copy) }
        case .saveCopyElsewhere(let destination):
            try? FileManager.default.copyItem(
                at: store.localURL(for: copy), to: destination)
            pendingConflicts.removeAll { $0.id == conflictID }
            pendingUploads.removeAll { $0.id == conflictID }
        case .dismiss:
            pendingConflicts.removeAll { $0.id == conflictID }
            pendingUploads.removeAll { $0.id == conflictID }
        }
    }

    private func performUpload(
        _ copy: RemoteEditStore.RemoteCopy, client: any SFTPClient
    ) async {
        let url = store.localURL(for: copy)
        do {
            // `.overwrite` is the intent (this *is* the remote file being
            // updated); `.remove` means a failed upload leaves no partial
            // next to it — the remote holds either the old file or the new
            // one, never a fragment.
            try await client.upload(
                from: url, to: copy.remotePath,
                policy: .overwrite, partialDisposition: .remove, progress: nil)
            let stamp = try? await client.lstat(path: copy.remotePath)
            store.updateRemoteStamp(
                copy, size: stamp?.size, mtime: stamp?.modificationTime)
            digests[copy.id] = RemoteEditStore.sha256Hex(ofFile: url)
            pendingUploads.removeAll { $0.id == copy.id }
            pendingConflicts.removeAll { $0.id == copy.id }
        } catch {
            // The pending entry stays: the decision is still owed, and the
            // wording is honest about the remote being untouched.
            presenter.showError(
                L10n.format(
                    "remoteEdit.uploadFailed", copy.remotePath, copy.host,
                    SFTPBrowserModel.errorMessage(Self.sftpError(error), host: copy.host)))
        }
    }

    private func redownload(_ copy: RemoteEditStore.RemoteCopy) async {
        do {
            let client = try await client(for: copy.host)
            let attributes = try await client.lstat(path: copy.remotePath)
            let url = store.localURL(for: copy)
            try await client.download(
                remotePath: copy.remotePath, to: url,
                policy: .overwrite, partialDisposition: .remove, progress: nil)
            store.updateRemoteStamp(
                copy, size: attributes.size, mtime: attributes.modificationTime)
            digests[copy.id] = RemoteEditStore.sha256Hex(ofFile: url)
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
    private static func sftpError(_ error: any Error) -> SFTPError {
        SFTPBrowserModel.sftpError(error)
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
                    "remoteEdit.changed.message", pending.copy.remotePath, pending.copy.host)
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
                        conflict.copy.remotePath, conflict.copy.host,
                        conflict.atDownloadDescription)
                    : L10n.format(
                        "remoteEdit.conflict.message",
                        conflict.copy.remotePath, conflict.copy.host,
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
                    panel.nameFieldStringValue =
                        (conflict.copy.remotePath as NSString).lastPathComponent
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
                    "remoteEdit.connect.message", remotePath, host)
                alert.addButton(withTitle: L10n.text("sftp.host.connect"))
                alert.addButton(withTitle: L10n.text("common.cancel"))
                return alert.runModal() == .alertFirstButtonReturn
            })
    }
}
