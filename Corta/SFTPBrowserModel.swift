import CortaTerminal
import Foundation
import Observation

/// B14 — the state and orchestration behind the SFTP browser window
/// (`SFTPBrowserView` renders it, `SFTPBrowserController` hosts it).
///
/// Everything the engine is asked for goes through the `SFTPClient`
/// protocol seam, injected as the `makeClient` factory, so the whole model
/// — navigation, typed error presentation, the transfer queue's states, the
/// conflict-choice mapping — is testable with a fake and never touches ssh.
///
/// **Conflicts are pre-flight, not mid-transfer.** The engine's `.decide`
/// policy callback is synchronous and runs on the transfer's own task; a
/// sheet cannot be presented from it without blocking an engine thread, and
/// "keep both" — renaming the destination — is not expressible through
/// `SFTPTransferEngine.ConflictResolution` at all. So the model gathers
/// what the engine would find (destination and partial, both ends' sizes
/// and mtimes) *before* starting, presents the choice, and maps the answer
/// onto `.overwrite` / `.resume` / `.fail`-at-a-renamed-destination, or
/// never starts the transfer at all. A race between the check and the
/// transfer still fails loudly: the chosen policy is what the engine then
/// enforces.
///
/// **Paths are absolute or nothing.** The path field rejects anything not
/// beginning with `/` rather than guessing a base directory — the session's
/// initial directory is resolved through REALPATH (`.`), and from there
/// every navigation lands on a canonical absolute path.
@MainActor
@Observable
final class SFTPBrowserModel {
    // MARK: - Entry model

    /// What one row of the listing is, decided from the ATTRS permission
    /// bits. `other` covers sockets, fifos and devices — displayed, but
    /// none of the operations pretend to know what to do with one.
    nonisolated enum Kind: Equatable {
        case file, directory, symlink, other

        var title: String {
            switch self {
            case .file: return L10n.text("sftp.kind.file")
            case .directory: return L10n.text("sftp.kind.directory")
            case .symlink: return L10n.text("sftp.kind.symlink")
            case .other: return L10n.text("sftp.kind.other")
            }
        }

        var symbolName: String {
            switch self {
            case .file: return "doc"
            case .directory: return "folder"
            case .symlink: return "link"
            case .other: return "questionmark.square.dashed"
            }
        }
    }

    nonisolated struct Entry: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let kind: Kind
        let size: UInt64?
        let modified: Date?
        /// The `drwxr-xr-x` rendering of the mode bits, when the server
        /// sent any.
        let permissions: String?
    }

    // MARK: - Connection state

    nonisolated enum ConnectionState: Equatable {
        /// Launched from a `.remoteUnknown` pane: the pane is remote, but
        /// no honest source names the host (the B13 rule — never the
        /// launcher's argv, never the screen). The user types it.
        case needsHost
        case connecting
        case connected
        /// Carries the already-presented message; the state itself, not
        /// the error, is what the view shows.
        case failed(message: String)
    }

    /// Volume capacity for the status line. `unsupported` is a real answer
    /// (the server does not speak `statvfs@openssh.com`), displayed as
    /// unavailable — never as a zero.
    nonisolated enum VolumeStatus: Equatable {
        case unknown
        case unsupported
        case available(free: UInt64, total: UInt64)
    }

    // MARK: - Transfers

    nonisolated enum TransferState: Equatable {
        /// Admitted to the engine's FIFO queue but not yet moving bytes.
        case queued
        case active(completed: UInt64, total: UInt64?)
        case cancelling
        /// `bytes` is the destination's final size, a resumed transfer's
        /// earlier partial included.
        case done(bytes: UInt64)
        /// `partialKept` is true exactly when the run left a resumable
        /// `.corta-part` behind (a resume-policy run) — surfaced, since a
        /// partial must never be silent.
        case cancelled(partialKept: Bool)
        case failed(message: String, retryable: Bool)
        /// The conflict sheet's Skip: the row stays as the record of the
        /// decision, and nothing was ever sent.
        case skipped
    }

    nonisolated struct Transfer: Identifiable, Equatable {
        let id: UUID
        let isUpload: Bool
        /// Display name — the file's own name, no path.
        let name: String
        var remotePath: String
        var localURL: URL
        let host: String
        var state: TransferState

        var label: String {
            L10n.format(
                isUpload ? "sftp.transfer.uploadLabel" : "sftp.transfer.downloadLabel",
                name, host)
        }
    }

    /// The engine policy a run executes under, chosen up front (see the
    /// type's doc comment). Stored on the plan so Retry repeats the same
    /// policy rather than asking again.
    nonisolated enum Resolution: Equatable {
        case fail, overwrite, resume

        var policy: SFTPTransferEngine.ConflictPolicy {
            switch self {
            case .fail: return .fail
            case .overwrite: return .overwrite
            case .resume: return .resume
            }
        }

        /// A resume run's partial is kept for a later resume; anything
        /// else's is removed, so a failed or cancelled transfer leaves
        /// either a whole destination or a visibly-named partial, never a
        /// silent one.
        var partialDisposition: SFTPTransferEngine.PartialDisposition {
            switch self {
            case .resume: return .keepForResume
            case .fail, .overwrite: return .remove
            }
        }
    }

    /// What the conflict sheet needs to render — both ends, preformatted.
    nonisolated struct ConflictPrompt: Identifiable, Equatable {
        let id: UUID
        let transferID: UUID
        /// The conflicting destination path, on whichever side is the
        /// destination.
        let path: String
        /// "4.2 MB, modified …" for each end, or a "does not exist" line.
        let sourceDescription: String
        let destinationDescription: String
        /// A partial exists, so Resume is meaningful to offer.
        let canResume: Bool
        /// Only a partial is in the way — the destination itself does not
        /// exist. The wording differs ("interrupted transfer") enough to
        /// be its own key.
        let partialOnly: Bool
    }

    nonisolated enum ConflictChoice {
        case overwrite, resume, keepBoth, skip
    }

    /// The confirmed-delete alert's content and payload.
    nonisolated struct DeleteConfirmation: Identifiable {
        let id = UUID()
        let entries: [Entry]
        let title: String
        let message: String
    }

    /// The new-directory / rename sheet: one text field, one action.
    nonisolated struct TextPrompt: Identifiable {
        enum Action: Equatable {
            case newDirectory
            case rename(Entry)
        }

        let id = UUID()
        let action: Action
        let title: String
        let message: String
        let initialText: String
    }

    /// What a download's destination choice means, from the picker: a save
    /// panel answers a full file URL (one file, possibly renamed), an
    /// open panel answers a directory the files land in by name.
    nonisolated enum DownloadDestination {
        case file(URL)
        case directory(URL)
    }

    // MARK: - Published state

    /// `nil` until a host is known — either from the pane (`.remote`) or
    /// typed in (`.needsHost`).
    private(set) var host: String?
    var hostField = ""
    private(set) var connectionState: ConnectionState
    private(set) var currentPath = "/"
    /// The path field's text, kept in sync with `currentPath` on every
    /// successful navigation; only its commit navigates, so half-typed
    /// paths never fire listings.
    var pathField = "/"
    private(set) var entries: [Entry] = []
    var selection: Set<String> = []
    var isLoading = false
    /// A failed listing/mkdir/rename/delete: shown inline, leaving the
    /// current directory's contents in place.
    var listingError: String?
    private(set) var volumeStatus: VolumeStatus = .unknown
    private(set) var transfers: [Transfer] = []

    /// The prompt states the view renders as sheets/alerts.
    var textPrompt: TextPrompt?
    var deleteConfirmation: DeleteConfirmation?
    private(set) var conflictPrompts: [ConflictPrompt] = []

    // MARK: - Wiring (set by the controller; the model never sees AppKit)

    /// Panels, injected because presenting one is the controller's job and
    /// because tests then never open one. A `nil` answer is a cancelled
    /// panel and starts nothing.
    var pickUploadFiles: (() async -> [URL])?
    var pickDownloadDestination: (([Entry]) async -> DownloadDestination?)?
    /// B14 remote editing — opens a file row in the editor, on a managed
    /// local copy (`RemoteEditCoordinator` owns download, watch and the
    /// upload-back decision). Set by the controller; any error wording is
    /// handed back for the listing's error line.
    var onEditFile: ((Entry) -> Void)?
    /// Called with the window's title text whenever it should change.
    var onTitleChange: ((String) -> Void)?
    /// Called once the connection succeeded, with the host actually
    /// connected to — how a user-entered host becomes the registry key.
    var onConnected: ((String) -> Void)?

    private let makeClient: @Sendable (String) -> any SFTPClient
    private var client: (any SFTPClient)?
    private let startDirectory: String?

    /// Everything needed to start a queued transfer once its conflict
    /// question is answered.
    private struct Plan {
        var isUpload: Bool
        var remotePath: String
        var localURL: URL
        var sourceSize: UInt64?
        var sourceModified: Date?
        var destinationExists = false
        var destinationSize: UInt64?
        var destinationModified: Date?
        var partialSize: UInt64?
    }

    private var plans: [UUID: Plan] = [:]
    private var resolutions: [UUID: Resolution] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Transfers cancelled while still in pre-flight — before any engine
    /// task exists to cancel. `start` checks this and never sends a byte
    /// for one.
    private var abandoned: Set<UUID> = []

    /// A host the pane *reported* but the user has not yet agreed to
    /// connect to (`RemoteHostConsent`): shown prefilled in the host field
    /// with wording that says where the name came from, and connected to
    /// only when the user says so. `nil` when there is no suggestion (a
    /// `.remoteUnknown` pane) or when `host` is already decided.
    let suggestedHost: String?

    init(
        host: String?,
        startDirectory: String?,
        suggestedHost: String? = nil,
        makeClient: (@Sendable (String) -> any SFTPClient)? = nil
    ) {
        self.host = host
        self.startDirectory = startDirectory
        self.suggestedHost = host == nil ? suggestedHost : nil
        if host == nil, let suggestedHost { hostField = suggestedHost }
        self.makeClient = makeClient ?? { SFTPConnection(host: $0) }
        connectionState = host == nil ? .needsHost : .connecting
    }

    // MARK: - Title

    /// `host:path` once connected — the connection never learns the user
    /// (ssh's config owns that), so none is shown rather than one
    /// invented.
    private func updateTitle() {
        let title: String
        switch connectionState {
        case .needsHost:
            title = L10n.text("sftp.window.untitled")
        case .connecting:
            title = L10n.format("sftp.connecting", host ?? hostField)
        case .connected:
            title = "\(host ?? ""):\(currentPath)"
        case .failed:
            title = host ?? L10n.text("sftp.window.untitled")
        }
        onTitleChange?(title)
    }

    // MARK: - Connect

    /// Starts (or retries, after a failure) the connection. With no host
    /// yet, the typed one is adopted; an empty field is a no-op. The guard
    /// is the client, not the state: a fresh model with a known host
    /// *starts* in `.connecting` (so the window shows progress from its
    /// first frame), and `.failed` clears the client, which is what makes
    /// Retry work. A live or in-flight connection is returned to as-is —
    /// re-presenting an open window must not spawn a second session.
    func connect() {
        guard client == nil else { return }
        let name: String
        if let host {
            name = host
        } else {
            let trimmed = hostField.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            host = trimmed
            name = trimmed
        }
        connectionState = .connecting
        listingError = nil
        updateTitle()
        let client = makeClient(name)
        self.client = client
        Task { await self.performConnect(client: client, host: name) }
    }

    private func performConnect(client: any SFTPClient, host name: String) async {
        do {
            _ = try await client.connect()
            // The pane's reported directory when there is one; otherwise
            // the session's own starting directory, canonicalised by the
            // server — never a guess at "~".
            let path: String
            if let startDirectory {
                path = startDirectory
            } else {
                path = try await client.realPath(path: ".")
            }
            let listing = try await client.listDirectory(path: path)
            connectionState = .connected
            currentPath = Self.normalized(path: path)
            pathField = currentPath
            applyEntries(listing)
            onConnected?(name)
            await refreshVolume()
        } catch {
            let error = Self.sftpError(error)
            connectionState = .failed(message: Self.errorMessage(error, host: name))
            client.close()
            self.client = nil
        }
        updateTitle()
    }

    /// Closes the session and abandons every transfer. Called by the
    /// controller when the window closes.
    func disconnect() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        client?.close()
        client = nil
    }

    // MARK: - Navigation

    /// The path field's commit. Absolute paths only — relative input is
    /// rejected with its own message rather than resolved against a base
    /// the user cannot see.
    func navigate(to path: String) {
        guard client != nil, connectionState == .connected else { return }
        guard path.hasPrefix("/") else {
            listingError = L10n.text("sftp.path.notAbsolute")
            return
        }
        load(path)
    }

    func navigateInto(_ entry: Entry) {
        guard entry.kind == .directory else { return }
        load(Self.joinPath(currentPath, entry.name))
    }

    func navigateUp() {
        guard currentPath != "/" else { return }
        load(Self.parentPath(of: currentPath))
    }

    func refresh() {
        guard connectionState == .connected else { return }
        load(currentPath)
    }

    private func load(_ path: String) {
        guard let client else { return }
        isLoading = true
        listingError = nil
        Task {
            do {
                let listing = try await client.listDirectory(path: path)
                currentPath = Self.normalized(path: path)
                pathField = currentPath
                applyEntries(listing)
                selection = []
                updateTitle()
                await refreshVolume()
            } catch {
                listingError = Self.errorMessage(Self.sftpError(error), host: host ?? "")
            }
            isLoading = false
        }
    }

    private func refreshVolume() async {
        guard let client else { return }
        do {
            if let info = try await client.volumeInfo(path: currentPath) {
                let total = info.blocks * info.blockSize
                let free = info.blocksAvailable * info.blockSize
                volumeStatus = .available(free: free, total: total)
            } else {
                volumeStatus = .unsupported
            }
        } catch {
            // Capacity is a nicety, not the listing: a failed statvfs
            // leaves the status line silent rather than replacing the
            // directory with an error.
            volumeStatus = .unknown
        }
    }

    private func applyEntries(_ listing: [SFTPEntry]) {
        entries =
            listing
            // `.` and `..` are the server's bookkeeping, not content.
            .filter { $0.filenameUTF8 != "." && $0.filenameUTF8 != ".." }
            .map { entry in
                let attributes = entry.attributes
                return Entry(
                    name: entry.filenameUTF8,
                    kind: Self.kind(ofPermissions: attributes.permissions),
                    size: attributes.size,
                    modified: attributes.modificationTime.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    permissions: attributes.permissions.map(Self.permissionString))
            }
            .sorted { lhs, rhs in
                if (lhs.kind == .directory) != (rhs.kind == .directory) {
                    return lhs.kind == .directory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Directory operations

    /// What the view's toolbar asks for; the model composes the prompt,
    /// the view renders it and hands the typed text back.
    func requestNewDirectory() {
        guard connectionState == .connected else { return }
        textPrompt = TextPrompt(
            action: .newDirectory,
            title: L10n.text("sftp.newDirectory.title"),
            message: L10n.format("sftp.newDirectory.message", currentPath),
            initialText: "")
    }

    func requestRename(_ entry: Entry) {
        guard connectionState == .connected else { return }
        textPrompt = TextPrompt(
            action: .rename(entry),
            title: L10n.text("sftp.rename.title"),
            message: L10n.format("sftp.rename.message", entry.name),
            initialText: entry.name)
    }

    /// The text sheet's confirm. A name that is empty, `.`/`..`, or
    /// contains `/` is rejected before the server ever hears about it.
    func commitTextPrompt(_ text: String) {
        guard let prompt = textPrompt else { return }
        textPrompt = nil
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            listingError = L10n.text("sftp.name.invalid")
            return
        }
        guard let client, let host else { return }
        let directory = currentPath
        Task {
            do {
                switch prompt.action {
                case .newDirectory:
                    try await client.makeDirectory(path: Self.joinPath(directory, name))
                case .rename(let entry):
                    try await client.rename(
                        from: Self.joinPath(directory, entry.name),
                        to: Self.joinPath(directory, name))
                }
                refresh()
            } catch {
                listingError = Self.errorMessage(Self.sftpError(error), host: host)
            }
        }
    }

    /// Composes the delete confirmation: host and path always, and for a
    /// directory the number of entries inside it (best-effort — the count
    /// is a courtesy, the server's own answer is authoritative; rmdir
    /// refuses a non-empty directory and that refusal is shown as such).
    func requestDelete(_ entries: [Entry]) {
        guard connectionState == .connected, !entries.isEmpty, let client, let host else { return }
        let directory = currentPath
        Task {
            var contained = 0
            for entry in entries where entry.kind == .directory {
                if let listing = try? await client.listDirectory(
                    path: Self.joinPath(directory, entry.name))
                {
                    contained += max(0, listing.count - 2)  // "." and ".."
                }
            }
            let title = L10n.format("sftp.delete.title", host)
            let message: String
            if entries.count == 1, let entry = entries.first {
                let path = Self.joinPath(directory, entry.name)
                message =
                    entry.kind == .directory
                    ? L10n.format("sftp.delete.message.directory", path, host, contained)
                    : L10n.format("sftp.delete.message.file", path, host)
            } else {
                message = L10n.format("sftp.delete.message.multiple", entries.count, host)
            }
            deleteConfirmation = DeleteConfirmation(
                entries: entries, title: title, message: message)
        }
    }

    func confirmDelete() {
        guard let confirmation = deleteConfirmation else { return }
        deleteConfirmation = nil
        guard let client, let host else { return }
        let directory = currentPath
        Task {
            for entry in confirmation.entries {
                do {
                    let path = Self.joinPath(directory, entry.name)
                    if entry.kind == .directory {
                        try await client.removeDirectory(path: path)
                    } else {
                        try await client.remove(path: path)
                    }
                } catch {
                    listingError = Self.errorMessage(Self.sftpError(error), host: host)
                }
            }
            refresh()
        }
    }

    // MARK: - Transfers: entry points

    /// Upload via the injected file picker; a cancelled panel starts
    /// nothing.
    func requestUpload() {
        guard connectionState == .connected, let pickUploadFiles else { return }
        Task {
            let urls = await pickUploadFiles()
            for url in urls {
                enqueue(
                    Plan(
                        isUpload: true,
                        remotePath: Self.joinPath(currentPath, url.lastPathComponent),
                        localURL: url))
            }
        }
    }

    /// Download via the injected destination picker (save panel for one
    /// file, directory chooser for several). Directories cannot be
    /// downloaded — the engine transfers files, and silently walking a
    /// remote tree is its own feature, not a button's side effect.
    func requestDownload() {
        guard connectionState == .connected, let pickDownloadDestination else { return }
        let chosen = selectedEntries.filter { $0.kind != .directory }
        guard !chosen.isEmpty else { return }
        Task {
            guard let destination = await pickDownloadDestination(chosen) else { return }
            for entry in chosen {
                let local: URL =
                    switch destination {
                    case .file(let url): url
                    case .directory(let directory):
                        directory.appendingPathComponent(entry.name)
                    }
                enqueue(
                    Plan(
                        isUpload: false,
                        remotePath: Self.joinPath(currentPath, entry.name),
                        localURL: local,
                        sourceSize: entry.size,
                        sourceModified: entry.modified))
            }
        }
    }

    var selectedEntries: [Entry] {
        entries.filter { selection.contains($0.id) }
    }

    /// Whether the Open action has something to open: exactly one
    /// directory selected.
    var canOpenSelection: Bool {
        selectedEntries.count == 1 && selectedEntries.first?.kind == .directory
    }

    /// Whether Download has anything it can act on.
    var canDownloadSelection: Bool {
        selectedEntries.contains { $0.kind != .directory }
    }

    /// Edit acts on exactly one plain file. A symlink is excluded on
    /// purpose: whether the copy should track the link or its target is a
    /// question the UI has no answer for yet, so it does not pretend.
    var canEditSelection: Bool {
        selectedEntries.count == 1 && selectedEntries.first?.kind == .file
    }

    /// The Edit button. The coordinator call itself is the controller's
    /// wiring (`onEditFile`); errors come back through `listingError`.
    func requestEdit() {
        guard canEditSelection, let entry = selectedEntries.first else { return }
        onEditFile?(entry)
    }

    // MARK: - Transfers: queue

    private func enqueue(_ plan: Plan) {
        guard let host else { return }
        let id = UUID()
        let name = plan.isUpload
            ? plan.localURL.lastPathComponent
            : (plan.remotePath as NSString).lastPathComponent
        transfers.append(
            Transfer(
                id: id, isUpload: plan.isUpload, name: name,
                remotePath: plan.remotePath, localURL: plan.localURL,
                host: host, state: .queued))
        plans[id] = plan
        Task { await preflight(id: id) }
    }

    /// Gathers what the engine's `.decide` callback would have been told,
    /// before anything is sent: whether the destination exists, whether a
    /// partial from an interrupted run is in the way, and both ends' sizes
    /// and mtimes for the sheet. Mirrors the engine's own checks — local
    /// attributes for a download's destination, LSTAT for an upload's.
    private func preflight(id: UUID) async {
        guard var plan = plans[id], let client else { return }
        if plan.isUpload {
            let local = try? FileManager.default.attributesOfItem(atPath: plan.localURL.path)
            plan.sourceSize = (local?[.size] as? NSNumber)?.uint64Value
            plan.sourceModified = local?[.modificationDate] as? Date
            let destination = try? await client.lstat(path: plan.remotePath)
            plan.destinationExists = destination != nil
            plan.destinationSize = destination?.size
            plan.destinationModified = destination?.modificationTime.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
            let partial = try? await client.lstat(
                path: SFTPTransferEngine.partialPath(for: plan.remotePath))
            plan.partialSize = partial?.size
        } else {
            let destination = try? FileManager.default.attributesOfItem(
                atPath: plan.localURL.path)
            plan.destinationExists = destination != nil
            plan.destinationSize = (destination?[.size] as? NSNumber)?.uint64Value
            plan.destinationModified = destination?[.modificationDate] as? Date
            let partial = try? FileManager.default.attributesOfItem(
                atPath: SFTPTransferEngine.partialPath(for: plan.localURL.path))
            plan.partialSize = (partial?[.size] as? NSNumber)?.uint64Value
        }
        plans[id] = plan
        // Cancelled while the pre-flight ran: the row is already settled.
        guard !abandoned.contains(id) else { return }
        guard plan.destinationExists || plan.partialSize != nil else {
            start(id: id, resolution: .fail)
            return
        }
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        conflictPrompts.append(
            ConflictPrompt(
                id: UUID(), transferID: id,
                path: transfer.isUpload ? plan.remotePath : plan.localURL.path,
                sourceDescription: Self.describe(
                    size: plan.sourceSize, modified: plan.sourceModified),
                // In the partial-only case the middle line describes the
                // partial itself — the destination genuinely is not there.
                destinationDescription: plan.destinationExists
                    ? Self.describe(
                        size: plan.destinationSize, modified: plan.destinationModified)
                    : Self.describe(size: plan.partialSize, modified: nil),
                canResume: plan.partialSize != nil,
                partialOnly: !plan.destinationExists))
    }

    /// The conflict sheet's answer, mapped onto engine policy (see the
    /// type's doc comment): Overwrite and Resume are the engine's own
    /// policies; Keep Both renames the destination and runs under `.fail`,
    /// so a race still fails rather than silently overwriting; Skip never
    /// starts the transfer, and the row records that.
    func resolveConflict(_ promptID: UUID, choice: ConflictChoice) {
        guard let prompt = conflictPrompts.first(where: { $0.id == promptID }) else { return }
        conflictPrompts.removeAll { $0.id == promptID }
        let id = prompt.transferID
        switch choice {
        case .skip:
            setState(id, .skipped)
            plans[id] = nil
        case .overwrite:
            start(id: id, resolution: .overwrite)
        case .resume:
            start(id: id, resolution: .resume)
        case .keepBoth:
            Task { await keepBoth(id: id) }
        }
    }

    /// Finds a `name 2.ext`-style destination that collides with neither a
    /// destination nor a partial, repoints the plan and row at it, and
    /// starts under `.fail`.
    private func keepBoth(id: UUID) async {
        guard var plan = plans[id], let client else { return }
        for attempt in 1...1000 {
            if plan.isUpload {
                let candidate = Self.keepBothCandidate(plan.remotePath, attempt: attempt)
                let destinationTaken = (try? await client.lstat(path: candidate)) != nil
                let partialTaken =
                    (try? await client.lstat(
                        path: SFTPTransferEngine.partialPath(for: candidate))) != nil
                if !destinationTaken && !partialTaken {
                    plan.remotePath = candidate
                    break
                }
            } else {
                let candidate = Self.keepBothCandidate(plan.localURL.path, attempt: attempt)
                let destinationTaken = FileManager.default.fileExists(atPath: candidate)
                let partialTaken = FileManager.default.fileExists(
                    atPath: SFTPTransferEngine.partialPath(for: candidate))
                if !destinationTaken && !partialTaken {
                    plan.localURL = URL(fileURLWithPath: candidate)
                    break
                }
            }
            if attempt == 1000 {
                setState(
                    id, .failed(
                        message: Self.errorMessage(
                            .destinationConflict(path: plan.remotePath), host: host ?? ""),
                        retryable: false))
                return
            }
        }
        plans[id] = plan
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].remotePath = plan.remotePath
            transfers[index].localURL = plan.localURL
        }
        start(id: id, resolution: .fail)
    }

    // MARK: - Transfers: running

    private func start(id: UUID, resolution: Resolution) {
        guard let plan = plans[id], let client, !abandoned.contains(id) else { return }
        resolutions[id] = resolution
        let task = Task { [weak self] in
            guard let self else { return }
            let progress: SFTPTransferEngine.ProgressHandler = { progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress, to: id)
                }
            }
            do {
                let receipt: SFTPTransferEngine.SFTPTransferReceipt
                if plan.isUpload {
                    receipt = try await client.upload(
                        from: plan.localURL, to: plan.remotePath,
                        policy: resolution.policy,
                        partialDisposition: resolution.partialDisposition,
                        progress: progress)
                } else {
                    receipt = try await client.download(
                        remotePath: plan.remotePath, to: plan.localURL,
                        policy: resolution.policy,
                        partialDisposition: resolution.partialDisposition,
                        progress: progress)
                }
                finish(id: id, receipt: receipt, isUpload: plan.isUpload)
            } catch {
                fail(id: id, error: Self.sftpError(error))
            }
        }
        tasks[id] = task
    }

    private func applyProgress(
        _ progress: SFTPTransferEngine.SFTPTransferProgress, to id: UUID
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].state {
        case .queued, .active:
            // Hops from the engine are not ordered; progress is, so a late
            // older value is dropped rather than regressing the bar.
            if case .active(let completed, _) = transfers[index].state,
                progress.completedBytes < completed
            { return }
            transfers[index].state = .active(
                completed: progress.completedBytes, total: progress.totalBytes)
        default:
            return
        }
    }

    private func finish(
        id: UUID, receipt: SFTPTransferEngine.SFTPTransferReceipt, isUpload: Bool
    ) {
        tasks[id] = nil
        plans[id] = nil
        setState(id, .done(bytes: receipt.bytesTransferred + receipt.resumedFromOffset))
        if isUpload { refresh() }
    }

    private func fail(id: UUID, error: SFTPError) {
        tasks[id] = nil
        let resumable = resolutions[id] == .resume
        switch error {
        case .cancelled:
            setState(id, .cancelled(partialKept: resumable))
        default:
            setState(
                id, .failed(
                    message: Self.errorMessage(error, host: host ?? ""),
                    retryable: error.isRetryableTransportFailure))
        }
    }

    private func setState(_ id: UUID, _ state: TransferState) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
    }

    /// Cancels one transfer — queued ones never reach the engine, running
    /// ones are abandoned mid-flight with the partial kept or removed per
    /// the run's resolution (the engine's guarantee). A transfer still in
    /// pre-flight has no task yet; it is simply never started.
    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].state {
        case .queued, .active:
            guard let task = tasks[id] else {
                abandoned.insert(id)
                plans[id] = nil
                transfers[index].state = .cancelled(partialKept: false)
                return
            }
            transfers[index].state = .cancelling
            task.cancel()
        default:
            return
        }
    }

    /// Retries a transport-class failure under the same resolution it ran
    /// with; a resume run's kept partial makes the retry continue where it
    /// stopped rather than start over.
    func retryTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
            case .failed(_, let retryable) = transfers[index].state, retryable,
            let resolution = resolutions[id]
        else { return }
        transfers[index].state = .queued
        start(id: id, resolution: resolution)
    }

    // MARK: - Pure helpers (the testable half)

    /// The row's kind from ATTRS's mode bits. No bits at all is displayed
    /// as a plain file — the common case for servers that omit ATTRS
    /// permissions — rather than as a spurious "other".
    nonisolated static func kind(ofPermissions permissions: UInt32?) -> Kind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }

    /// `drwxr-xr-x` — the `ls -l` rendering of a mode word, set-ID and
    /// sticky bits included.
    nonisolated static func permissionString(_ mode: UInt32) -> String {
        let type: Character =
            switch mode & 0o170000 {
            case 0o040000: "d"
            case 0o120000: "l"
            case 0o060000: "b"
            case 0o020000: "c"
            case 0o010000: "p"
            case 0o140000: "s"
            default: "-"
            }
        var result = String(type)
        // (read, write, execute, set-ID/sticky, its letter) per triple.
        let triples: [(r: UInt32, w: UInt32, x: UInt32, special: UInt32, letter: Character)] = [
            (0o400, 0o200, 0o100, 0o4000, "s"),  // owner, setuid
            (0o040, 0o020, 0o010, 0o2000, "s"),  // group, setgid
            (0o004, 0o002, 0o001, 0o1000, "t"),  // other, sticky
        ]
        for triple in triples {
            result.append(mode & triple.r != 0 ? "r" : "-")
            result.append(mode & triple.w != 0 ? "w" : "-")
            let execute = mode & triple.x != 0
            if mode & triple.special != 0 {
                result.append(
                    execute ? triple.letter : Character(triple.letter.uppercased()))
            } else {
                result.append(execute ? "x" : "-")
            }
        }
        return result
    }

    /// Remote path joining — "/" is the only separator, and the root is
    /// the only directory that already ends in one.
    nonisolated static func joinPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    nonisolated static func parentPath(of path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else {
            return "/"
        }
        return String(trimmed[trimmed.startIndex..<slash])
    }

    /// Strips a trailing slash, so `/usr/` and `/usr` are the same
    /// current-path display; the root survives.
    nonisolated static func normalized(path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One keep-both candidate: `report.pdf` → `report 2.pdf` at attempt 1,
    /// `report 3.pdf` at 2; an extensionless name appends at the end.
    nonisolated static func keepBothCandidate(_ path: String, attempt: Int) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let name = nsPath.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let `extension` = (name as NSString).pathExtension
        let base = `extension`.isEmpty ? name : stem
        let candidate = "\(base) \(attempt + 1)"
        let renamed = `extension`.isEmpty ? candidate : "\(candidate).\(`extension`)"
        return directory.isEmpty ? renamed : "\(directory)/\(renamed)"
    }

    /// "4.2 MB, modified 12 Sep 2026 …", or the unknown wording when the
    /// server did not say. MainActor, like the formatter it reads.
    static func describe(size: UInt64?, modified: Date?) -> String {
        let sizeText =
            size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? L10n.text("sftp.size.unknown")
        guard let modified else { return sizeText }
        return L10n.format(
            "sftp.conflict.sizeAndTime", sizeText,
            Self.modificationFormatter.string(from: modified))
    }

    private static let modificationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The typed error categories, each in its own words — an auth failure
    /// is not "the host is unreachable", and neither is a generic "error".
    nonisolated static func errorMessage(_ error: SFTPError, host: String) -> String {
        switch error {
        case .server(let status):
            if status.code == .permissionDenied {
                return L10n.format("sftp.error.permissionDenied", host, status.messageString)
            }
            return L10n.format(
                "sftp.error.server", host, Int(status.code.rawValue), status.messageString)
        case .transport(let transport):
            switch transport {
            case .authenticationFailed(let diagnostics):
                return L10n.format(
                    "sftp.error.authentication", host, trimmedDiagnostics(diagnostics))
            case .hostUnreachable(let diagnostics):
                return L10n.format(
                    "sftp.error.unreachable", host, trimmedDiagnostics(diagnostics))
            case .hostKeyUnverified(let diagnostics):
                return L10n.format(
                    "sftp.error.hostKey", host, trimmedDiagnostics(diagnostics))
            case .subprocessFailed(let code, let diagnostics):
                return L10n.format(
                    "sftp.error.subprocess", host, code, trimmedDiagnostics(diagnostics))
            case .spawnFailed(let code):
                return L10n.format("sftp.error.spawn", code)
            case .executablePathNotAbsolute:
                return L10n.text("sftp.error.spawnPath")
            case .ioFailed(let code):
                return L10n.format("sftp.error.channel", host, code)
            case .closed, .connectionLost:
                return L10n.format("sftp.error.connectionLost", host)
            }
        case .protocolViolation(let detail):
            return L10n.format("sftp.error.protocol", host, detail)
        case .cancelled:
            return L10n.text("sftp.transfer.cancelled")
        case .destinationConflict(let path):
            return L10n.format("sftp.error.conflict", path)
        case .localIOFailed(let operation, let code):
            return L10n.format("sftp.error.localIO", operation, code)
        }
    }

    /// The ssh stderr tail, trimmed of its trailing newlines for display.
    nonisolated static func trimmedDiagnostics(_ diagnostics: String) -> String {
        diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Narrowing for plain `catch` clauses: this toolchain binds a
    /// catch-all's `error` as `any Error` even when the do-block only
    /// throws `SFTPError` (and warns on the always-true typed catch
    /// instead). Anything that is not an `SFTPError` here is a bug in the
    /// client, reported as a violation rather than dropped — except a bare
    /// `CancellationError`, which means exactly one thing.
    nonisolated static func sftpError(_ error: any Error) -> SFTPError {
        if error is CancellationError { return .cancelled }
        return (error as? SFTPError) ?? .protocolViolation("\(error)")
    }
}
