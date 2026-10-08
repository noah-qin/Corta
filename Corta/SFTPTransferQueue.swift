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

import CortaSFTP
import CortaTerminal
import Foundation
import Observation
import Synchronization

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
        /// Smoothed throughput while active, for the row's speed and time
        /// left; `nil` until two samples far enough apart have arrived.
        var bytesPerSecond: Double?
        /// The last sample the rate was taken from.
        var sampleTime: TimeInterval?
        var sampleBytes: UInt64 = 0

        /// Seconds left at the current rate, when both the total and a rate
        /// are known.
        var remainingSeconds: Double? {
            guard case .active(let completed, let total?) = state, let bytesPerSecond,
                bytesPerSecond > 0, total >= completed
            else { return nil }
            return Double(total - completed) / bytesPerSecond
        }

        /// Finished one way or another: nothing more will happen to the row
        /// unless a retry is asked for.
        var isFinished: Bool {
            switch state {
            case .done, .cancelled, .failed, .skipped: return true
            case .queued, .active, .cancelling: return false
            }
        }

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
    /// The clock rates are measured on; a test supplies its own.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Called once when a transfer reaches a terminal state — how a drag to
    /// Finder waits for the download it started, through the same queue
    /// (and the same progress row) as any other.
    private var finishHandlers: [UUID: (Result<URL, TransferFailure>) -> Void] = [:]

    nonisolated struct TransferFailure: Error, Equatable {
        let message: String
    }

    /// Transfers still queued or moving — the toolbar button's badge.
    var activeCount: Int { transfers.count(where: { !$0.isFinished }) }

    /// All running byte counts as one fraction, for the toolbar's ring;
    /// `nil` while nothing with a known size is moving.
    var overallProgress: Double? {
        // Peer sizes span UInt64; even two valid values can overflow an
        // integer sum. Floating point is sufficient for a display fraction.
        var completed: Double = 0
        var total: Double = 0
        for transfer in transfers {
            guard case .active(let done, let size?) = transfer.state, size > 0 else { continue }
            completed += Double(min(done, size))
            total += Double(size)
        }
        return total > 0 ? completed / total : nil
    }

    /// Clears the rows that are over — done, cancelled, skipped or failed —
    /// the way Safari's Downloads list does. Running ones stay.
    func clearFinished() {
        for transfer in transfers where transfer.isFinished {
            jobs[transfer.id] = nil
        }
        transfers.removeAll(where: \.isFinished)
    }

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
        /// The host the row names; the queue's `client` follows Change Host.
        let host: String
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
        enqueue(plan, onFinish: nil)
    }

    /// `onFinish` hears the outcome once: the local file for a finished
    /// download (or the source for an upload), a failure otherwise. Without
    /// a connection it hears the failure at once.
    func enqueue(_ plan: Plan, onFinish: ((Result<URL, TransferFailure>) -> Void)?) {
        guard let host, client != nil else {
            onFinish?(.failure(TransferFailure(message: L10n.format("sftp.error.connectionLost", host ?? ""))))
            return
        }
        let id = UUID()
        if let onFinish { finishHandlers[id] = onFinish }
        let name =
            plan.isUpload
            ? plan.localURL.lastPathComponent
            : (plan.remotePath as NSString).lastPathComponent
        transfers.append(
            Transfer(
                id: id, isUpload: plan.isUpload, isDirectory: plan.isDirectory, name: name,
                remotePath: plan.remotePath, localURL: plan.localURL,
                host: host, state: .queued))
        jobs[id] = Job(plan: plan, host: host)
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

    /// Lets a progress report through at most every `interval`; called from
    /// the engine's tasks, so the clock is behind a lock.
    nonisolated final class ProgressPacer: Sendable {
        private let last = Mutex<ContinuousClock.Instant?>(nil)
        private let interval: Duration

        init(interval: Duration = .milliseconds(50)) { self.interval = interval }

        func admits(now: ContinuousClock.Instant = .now) -> Bool {
            last.withLock { last in
                if let previous = last, previous.duration(to: now) < interval { return false }
                last = now
                return true
            }
        }
    }

    private func start(id: UUID, resolution: Resolution) {
        guard let job = jobs[id], let client else { return }
        // A failed row outlives Change Host, and its Retry ran on whichever
        // machine the browser was on by then: a file queued for one host
        // went to another. It runs only where the row says it goes.
        guard job.host == host else {
            jobs[id] = nil
            setState(
                id,
                .failed(
                    message: L10n.format("sftp.error.connectionLost", job.host),
                    retryable: false))
            return
        }
        let plan = job.plan
        jobs[id]?.resolution = resolution
        let task = Task { [weak self] in
            guard let self else { return }
            // The engine reports every 32 KiB block — thousands a second on a
            // fast link, each a main-actor hop and a list redraw. A row needs a
            // few a second; the receipt sets the final state.
            let pacer = ProgressPacer()
            let progress: SFTPTransferEngine.ProgressHandler = { [weak self] progress in
                guard pacer.admits() else { return }
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress, to: id)
                }
            }
            do {
                if plan.isDirectory {
                    let directoryProgress: SFTPTransferEngine.DirectoryProgressHandler = {
                        [weak self] p in
                        guard pacer.admits() else { return }
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
            transfers[index] = Self.updatedRate(
                transfers[index], completed: progress.completedBytes, now: now())
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
            transfers[index] = Self.updatedRate(
                transfers[index], completed: progress.completedBytes, now: now())
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
        if case .active = state {} else { transfers[index].bytesPerSecond = nil }
        guard transfers[index].isFinished, let handler = finishHandlers.removeValue(forKey: id)
        else { return }
        switch state {
        case .done:
            let transfer = transfers[index]
            handler(.success(transfer.localURL))
        case .failed(let message, _):
            handler(.failure(TransferFailure(message: message)))
        default:
            handler(.failure(TransferFailure(message: L10n.text("sftp.transfer.cancelled"))))
        }
    }

    /// Folds a progress sample into the transfer's rate: a sample is taken
    /// at most every half second, and each moves the rate a third of the
    /// way towards the latest, so the shown speed neither jitters nor lags.
    nonisolated static func updatedRate(
        _ transfer: Transfer, completed: UInt64, now: TimeInterval
    ) -> Transfer {
        var transfer = transfer
        guard let last = transfer.sampleTime else {
            transfer.sampleTime = now
            transfer.sampleBytes = completed
            return transfer
        }
        let elapsed = now - last
        guard elapsed >= 0.5 else { return transfer }
        guard completed >= transfer.sampleBytes else {
            // A retry or resume restarted the count: start sampling over.
            transfer.sampleTime = now
            transfer.sampleBytes = completed
            transfer.bytesPerSecond = nil
            return transfer
        }
        let instant = Double(completed - transfer.sampleBytes) / elapsed
        transfer.bytesPerSecond = transfer.bytesPerSecond.map { $0 + (instant - $0) / 3 } ?? instant
        transfer.sampleTime = now
        transfer.sampleBytes = completed
        return transfer
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
                setState(id, .cancelled(partialKept: false))
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
        transfers[index].sampleTime = nil
        transfers[index].bytesPerSecond = nil
        start(id: id, resolution: resolution)
    }

}

#if DEBUG
extension SFTPTransferQueue {
    /// Display-only rows: no jobs, filesystem staging, or transfer tasks.
    func installDevelopmentPreview() {
        let samples: [(String, Bool, TransferState)] = [
            ("archive.zip", false, .active(completed: 4_194_304, total: 10_485_760)),
            ("README.md", true, .done(bytes: 2048)),
            ("backup.tar.gz", false, .failed(message: L10n.text("ui.demo.error"), retryable: false))
        ]
        transfers = samples.map { name, upload, state in
            Transfer(id: UUID(), isUpload: upload, name: name, remotePath: "/home/demo/" + name,
                     localURL: URL(fileURLWithPath: "/development-preview/" + name), host: "demo.invalid", state: state)
        }
    }
}
#endif
