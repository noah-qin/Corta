import CortaTerminal
import Foundation
import Observation

/// Owns transfer planning, conflicts, cancellation and retry for one browser connection.
/// Resolve conflicts before starting: the engine cannot present an asynchronous sheet.
/// Each job retains its plan, chosen policy and running task together.
@MainActor
@Observable
final class SFTPTransferQueue {
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
        /// A directory transfer; the row shows files done of files total
        /// alongside the bytes.
        var isDirectory = false
        /// Directory transfers only: files completed and the total the
        /// walk found, for the row.
        var filesCompleted = 0
        var filesTotal = 0
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

    var client: (any SFTPClient)?
    var host: String?
    var onUploadFinished: (() -> Void)?
    var onListingError: ((String) -> Void)?
    private(set) var transfers: [Transfer] = []
    private(set) var conflictPrompts: [ConflictPrompt] = []

    /// Everything needed to start a queued transfer once its conflict
    /// question is answered.
    struct Plan {
        var isUpload: Bool
        /// A whole tree (`SFTPTransferEngine.uploadDirectory`/
        /// `downloadDirectory`) rather than one file. Directories merge and
        /// the conflict policy applies per file inside, so the pre-flight
        /// only asks whether the destination directory already exists.
        var isDirectory = false
        var remotePath: String
        var localURL: URL
        var sourceSize: UInt64?
        var sourceModified: Date?
        var destinationExists = false
        var destinationSize: UInt64?
        var destinationModified: Date?
        var partialSize: UInt64?
    }

    private struct Job {
        var plan: Plan
        var resolution: Resolution?
        var task: Task<Void, Never>?
    }

    private var jobs: [UUID: Job] = [:]

    func disconnect() {
        for id in Array(jobs.keys) {
            cancelTransfer(id)
        }
        client = nil
    }

    // MARK: - Transfers: queue

    func enqueue(_ plan: Plan) {
        guard let host, client != nil else { return }
        let id = UUID()
        let name =
            plan.isUpload
            ? plan.localURL.lastPathComponent
            : (plan.remotePath as NSString).lastPathComponent
        transfers.append(
            Transfer(
                id: id, isUpload: plan.isUpload, isDirectory: plan.isDirectory, name: name,
                remotePath: plan.remotePath, localURL: plan.localURL,
                host: host, state: .queued))
        jobs[id] = Job(plan: plan)
        Task { await preflight(id: id) }
    }

    /// Gathers what the engine's `.decide` callback would have been told,
    /// before anything is sent: whether the destination exists, whether a
    /// partial from an interrupted run is in the way, and both ends' sizes
    /// and mtimes for the sheet. Mirrors the engine's own checks — local
    /// attributes for a download's destination, LSTAT for an upload's.
    private func preflight(id: UUID) async {
        guard var plan = jobs[id]?.plan, let client else { return }
        if plan.isDirectory {
            // Directories merge; the only question is whether one is
            // already there, and the sheet's answer becomes the per-file
            // policy inside. Partials belong to the files, not the tree.
            if plan.isUpload {
                plan.destinationExists = (try? await client.lstat(path: plan.remotePath)) != nil
            } else {
                plan.destinationExists = FileManager.default.fileExists(atPath: plan.localURL.path)
            }
            jobs[id]?.plan = plan
            guard jobs[id] != nil else { return }
            guard plan.destinationExists else {
                start(id: id, resolution: .fail)
                return
            }
            guard let transfer = transfers.first(where: { $0.id == id }) else { return }
            conflictPrompts.append(
                ConflictPrompt(
                    id: UUID(), transferID: id,
                    path: transfer.isUpload ? plan.remotePath : plan.localURL.path,
                    sourceDescription: L10n.text("sftp.conflict.directory"),
                    destinationDescription: L10n.text("sftp.conflict.directoryExists"),
                    canResume: true, partialOnly: false))
            return
        }
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
        jobs[id]?.plan = plan
        // Cancelled while the pre-flight ran: the row is already settled.
        guard jobs[id] != nil else { return }
        guard plan.destinationExists || plan.partialSize != nil else {
            start(id: id, resolution: .fail)
            return
        }
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        conflictPrompts.append(
            ConflictPrompt(
                id: UUID(), transferID: id,
                path: transfer.isUpload ? plan.remotePath : plan.localURL.path,
                sourceDescription: SFTPBrowserModel.describe(
                    size: plan.sourceSize, modified: plan.sourceModified),
                // In the partial-only case the middle line describes the
                // partial itself — the destination genuinely is not there.
                destinationDescription: plan.destinationExists
                    ? SFTPBrowserModel.describe(
                        size: plan.destinationSize, modified: plan.destinationModified)
                    : SFTPBrowserModel.describe(size: plan.partialSize, modified: nil),
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
            jobs[id] = nil
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
        guard var plan = jobs[id]?.plan, let client else { return }
        for attempt in 1...1000 {
            if plan.isUpload {
                let candidate = SFTPBrowserModel.keepBothCandidate(
                    plan.remotePath, attempt: attempt)
                let destinationTaken = (try? await client.lstat(path: candidate)) != nil
                let partialTaken =
                    (try? await client.lstat(
                        path: SFTPTransferEngine.partialPath(for: candidate))) != nil
                if !destinationTaken && !partialTaken {
                    plan.remotePath = candidate
                    break
                }
            } else {
                let candidate = SFTPBrowserModel.keepBothCandidate(
                    plan.localURL.path, attempt: attempt)
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
                    id,
                    .failed(
                        message: SFTPBrowserModel.errorMessage(
                            .destinationConflict(path: plan.remotePath), host: host ?? ""),
                        retryable: false))
                return
            }
        }
        jobs[id]?.plan = plan
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].remotePath = plan.remotePath
            transfers[index].localURL = plan.localURL
        }
        start(id: id, resolution: .fail)
    }

    // MARK: - Transfers: running

    private func start(id: UUID, resolution: Resolution) {
        guard let plan = jobs[id]?.plan, let client else { return }
        jobs[id]?.resolution = resolution
        let task = Task { [weak self] in
            guard let self else { return }
            let progress: SFTPTransferEngine.ProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress, to: id)
                }
            }
            do {
                if plan.isDirectory {
                    let directoryProgress: SFTPTransferEngine.DirectoryProgressHandler = {
                        [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.applyDirectoryProgress(p, to: id)
                        }
                    }
                    let receipt: SFTPTransferEngine.DirectoryTransferReceipt
                    if plan.isUpload {
                        receipt = try await client.uploadDirectory(
                            from: plan.localURL, to: plan.remotePath,
                            policy: resolution.policy, progress: directoryProgress)
                    } else {
                        receipt = try await client.downloadDirectory(
                            remotePath: plan.remotePath, to: plan.localURL,
                            policy: resolution.policy, progress: directoryProgress)
                    }
                    finishDirectory(id: id, receipt: receipt, isUpload: plan.isUpload)
                    return
                }
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
                fail(id: id, error: SFTPBrowserModel.sftpError(error))
            }
        }
        jobs[id]?.task = task
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
            {
                return
            }
            transfers[index].state = .active(
                completed: progress.completedBytes, total: progress.totalBytes)
        default:
            return
        }
    }

    private func applyDirectoryProgress(
        _ progress: SFTPTransferEngine.DirectoryTransferProgress, to id: UUID
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].state {
        case .queued, .active:
            if case .active(let completed, _) = transfers[index].state,
                progress.completedBytes < completed
            {
                return
            }
            transfers[index].filesCompleted = progress.filesCompleted
            transfers[index].filesTotal = progress.filesTotal
            transfers[index].state = .active(
                completed: progress.completedBytes, total: progress.totalBytes)
        default:
            return
        }
    }

    /// A directory's receipt: the row records the bytes, and anything the
    /// walk skipped (symbolic links, special files, unsafe names) is
    /// surfaced on the listing's error line — a skipped entry must never
    /// be silent.
    private func finishDirectory(
        id: UUID, receipt: SFTPTransferEngine.DirectoryTransferReceipt, isUpload: Bool
    ) {
        jobs[id] = nil
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].filesCompleted = receipt.filesTransferred
            transfers[index].filesTotal = receipt.filesTransferred
        }
        setState(id, .done(bytes: receipt.bytesTransferred))
        if !receipt.skipped.isEmpty {
            onListingError?(
                L10n.format(
                    "sftp.directory.skipped", receipt.skipped.count,
                    receipt.skipped.prefix(3).map(\.relativePath).joined(separator: ", ")))
        }
        if isUpload { onUploadFinished?() }
    }

    private func finish(
        id: UUID, receipt: SFTPTransferEngine.SFTPTransferReceipt, isUpload: Bool
    ) {
        jobs[id] = nil
        setState(id, .done(bytes: receipt.bytesTransferred + receipt.resumedFromOffset))
        if isUpload { onUploadFinished?() }
    }

    private func fail(id: UUID, error: SFTPError) {
        jobs[id]?.task = nil
        let resumable = jobs[id]?.resolution == .resume
        switch error {
        case .cancelled:
            setState(id, .cancelled(partialKept: resumable))
        default:
            setState(
                id,
                .failed(
                    message: SFTPBrowserModel.errorMessage(error, host: host ?? ""),
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
            guard let task = jobs[id]?.task else {
                jobs[id] = nil
                conflictPrompts.removeAll { $0.transferID == id }
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
            let resolution = jobs[id]?.resolution
        else { return }
        transfers[index].state = .queued
        start(id: id, resolution: resolution)
    }

}
