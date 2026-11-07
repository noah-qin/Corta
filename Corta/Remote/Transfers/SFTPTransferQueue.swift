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
import Foundation
import Observation

/// Owns transfer planning, conflicts, cancellation and retry for one browser connection.
/// Resolve conflicts before starting: the engine cannot present an asynchronous sheet.
/// Each job retains its plan, chosen policy and running task together.
@MainActor
@Observable
final class SFTPTransferQueue {
    // MARK: - Transfers

    var client: (any SFTPClient)?
    var host: String?
    var onUploadFinished: (() -> Void)?
    var onListingError: ((String) -> Void)?
    var transfers: [Transfer] = []
    var conflictPrompts: [ConflictPrompt] = []
    /// The clock rates are measured on; a test supplies its own.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Called once when a transfer reaches a terminal state — how a drag to
    /// Finder waits for the download it started, through the same queue
    /// (and the same progress row) as any other.
    var finishHandlers: [UUID: (Result<URL, TransferFailure>) -> Void] = [:]
    /// Everything local the queue asks about a file, off the main actor.
    var localChecks = SFTPLocalChecks()
    /// How long a cancelled row may wait for its transfer to stop before it
    /// says Cancelled anyway. A transfer stops at its next check, but a read
    /// from a volume that has gone may not come back to one; the destination
    /// is safe either way (the engine commits only whole files).
    var cancellingTimeout: Duration = .seconds(10)

    /// Clears the rows that are over — done, cancelled, skipped or failed —
    /// the way Safari's Downloads list does. Running ones stay.
    func clearFinished() {
        for transfer in transfers where transfer.isFinished {
            jobs[transfer.id] = nil
        }
        transfers.removeAll(where: \.isFinished)
    }

    struct Job {
        var plan: Plan
        /// The host the row names; the queue's `client` follows Change Host.
        let host: String
        var resolution: Resolution?
        var task: Task<Void, Never>?
        /// The pre-flight or Keep Both search before there is a `task`: only
        /// questions, cancelled with the row.
        var preparation: Task<Void, Never>?
        /// Which `start` `task` is. A run given up on may still finish, after
        /// a Retry has started another; it speaks only for itself.
        var run = UUID()
    }

    var jobs: [UUID: Job] = [:]

    func disconnect() {
        for id in Array(jobs.keys) {
            cancelTransfer(id)
        }
        client = nil
    }

}

// MARK: - Transfers: queue

extension SFTPTransferQueue {

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
        let name = SFTPBrowserModel.displayName(
            plan.isUpload
                ? plan.localURL.lastPathComponent
                : (plan.remotePath as NSString).lastPathComponent)
        transfers.append(
            Transfer(
                id: id, isUpload: plan.isUpload, isDirectory: plan.isDirectory, name: name,
                localURL: plan.localURL,
                host: host, state: .queued, revealsInFinder: onFinish == nil))
        jobs[id] = Job(plan: plan, host: host)
        jobs[id]?.preparation = Task { await preflight(id: id) }
    }

    /// Gathers what the engine's `.decide` callback would have been told,
    /// before anything is sent: whether the destination exists, whether a
    /// partial from an interrupted run is in the way, and both ends' sizes
    /// and mtimes for the sheet. Mirrors the engine's own checks — local
    /// attributes for a download's destination, LSTAT for an upload's.
    func preflight(id: UUID) async {
        guard var plan = jobs[id]?.plan, let client, runsHere(id) else { return }
        // A chosen folder merges; the only question is whether one is already
        // there, and the sheet's answer becomes the per-file policy inside.
        // Partials belong to the files, not the tree.
        if plan.isUpload {
            let url = plan.localURL
            let result = await localChecks.answer { SFTPLocalFacts.source(url) }
            guard let source = checked(result, id: id, path: url.path) else { return }
            plan.isDirectory = plan.isDirectory || source.isDirectory
            if let index = transfers.firstIndex(where: { $0.id == id }) {
                transfers[index].isDirectory = plan.isDirectory
            }
            if plan.isDirectory {
                plan.destinationExists = (try? await client.lstat(path: plan.remotePath)) != nil
            } else {
                plan.sourceSize = source.attributes.size
                plan.sourceModified = source.attributes.modified
                await Self.inspectUpload(&plan, client: client)
            }
        } else {
            let path = plan.localURL.path
            let result = await localChecks.answer { SFTPLocalFacts.destination(atPath: path) }
            guard let found = checked(result, id: id, path: path) else { return }
            plan.destinationExists = found.destination.exists
            if !plan.isDirectory {
                // The source's size and mtime arrive with the listing the
                // plan was made from.
                plan.destinationSize = found.destination.size
                plan.destinationModified = found.destination.modified
                plan.partialSize = found.partial.size
            }
        }
        // Cancelled while the pre-flight ran: the row is already settled.
        guard !Task.isCancelled, jobs[id] != nil else { return }
        jobs[id]?.plan = plan
        jobs[id]?.preparation = nil
        guard plan.destinationExists || plan.partialSize != nil else {
            start(id: id, resolution: .fail)
            return
        }
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        conflictPrompts.append(Self.conflictPrompt(for: plan, transferID: id, isUpload: transfer.isUpload))
    }

    private static func conflictPrompt(for plan: Plan, transferID id: UUID, isUpload: Bool) -> ConflictPrompt {
        let path = SFTPBrowserModel.peerText(isUpload ? plan.remotePath : plan.localURL.path)
        if plan.isDirectory {
            return ConflictPrompt(
                id: UUID(), transferID: id, path: path,
                sourceDescription: L10n.text("sftp.conflict.directory"),
                destinationDescription: L10n.text("sftp.conflict.directoryExists"),
                canResume: true, partialOnly: false)
        }
        return ConflictPrompt(
            id: UUID(), transferID: id, path: path,
            sourceDescription: SFTPBrowserModel.describe(
                size: plan.sourceSize, modified: plan.sourceModified),
            // In the partial-only case the middle line describes the
            // partial itself — the destination genuinely is not there.
            destinationDescription: plan.destinationExists
                ? SFTPBrowserModel.describe(
                    size: plan.destinationSize, modified: plan.destinationModified)
                : SFTPBrowserModel.describe(size: plan.partialSize, modified: nil),
            canResume: plan.partialSize != nil,
            partialOnly: !plan.destinationExists)
    }

    /// An upload's remote facts for the sheet: the destination and partial by
    /// LSTAT.
    private static func inspectUpload(_ plan: inout Plan, client: any SFTPClient) async {
        let destination = try? await client.lstat(path: plan.remotePath)
        plan.destinationExists = destination != nil
        plan.destinationSize = destination?.size
        plan.destinationModified = destination?.modificationTime.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let partial = try? await client.lstat(
            path: SFTPTransferEngine.partialPath(for: plan.remotePath))
        plan.partialSize = partial?.size
    }

    /// The disk did not answer. Unless the row was cancelled meanwhile, it
    /// fails — Retry asks again — and the rest of the queue goes on.
    private func checked<T>(_ result: Result<T, SFTPLocalChecks.Failure>, id: UUID, path: String) -> T? {
        guard !Task.isCancelled, jobs[id] != nil else { return nil }
        switch result {
        case .success(let value):
            return value
        case .failure(.cancelled):
            return nil
        case .failure(let failure):
            jobs[id]?.preparation = nil
            let key = failure == .budgetExhausted
                ? "sftp.transfer.localCheckUnavailable" : "sftp.transfer.localCheckTimedOut"
            setState(id, .failed(
                message: L10n.format(key, SFTPBrowserModel.peerText(path)), retryable: finishHandlers[id] == nil))
            return nil
        }
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
            jobs[id]?.preparation = Task { await keepBoth(id: id) }
        }
    }

    /// Finds a `name 2.ext`-style destination that collides with neither a
    /// destination nor a partial, repoints the plan and row at it, and
    /// starts under `.fail`.
    private func keepBoth(id: UUID) async {
        guard var plan = jobs[id]?.plan, let client else { return }
        let attempts = 1000
        var candidate: String?
        if plan.isUpload {
            let remotePath = plan.remotePath
            for first in stride(from: 1, through: attempts, by: 8) {
                guard !Task.isCancelled, jobs[id] != nil else { return }
                let free = await withTaskGroup(of: Int?.self) { group in
                    for attempt in first...min(attempts, first + 7) {
                        group.addTask {
                            let name = SFTPBrowserModel.keepBothCandidate(remotePath, attempt: attempt)
                            async let destination = try? client.lstat(path: name)
                            async let partial = try? client.lstat(path: SFTPTransferEngine.partialPath(for: name))
                            let (file, fragment) = await (destination, partial)
                            return file == nil && fragment == nil ? attempt : nil
                        }
                    }
                    var earliest: Int?
                    for await result in group {
                        if let result { earliest = min(earliest ?? result, result) }
                    }
                    return earliest
                }
                if let free {
                    candidate = SFTPBrowserModel.keepBothCandidate(remotePath, attempt: free)
                    break
                }
            }
        } else {
            let path = plan.localURL.path
            let result = await localChecks.answer {
                SFTPLocalFacts.firstFreeCandidate(for: path, attempts: attempts)
            }
            guard let answer = checked(result, id: id, path: path) else { return }
            candidate = answer
        }
        guard !Task.isCancelled, jobs[id] != nil else { return }
        jobs[id]?.preparation = nil
        guard let candidate else {
            setState(
                id,
                .failed(
                    message: SFTPBrowserModel.errorMessage(
                        .destinationConflict(path: plan.isUpload ? plan.remotePath : plan.localURL.path),
                        host: host ?? ""),
                    retryable: false))
            return
        }
        if plan.isUpload {
            plan.remotePath = candidate
        } else {
            plan.localURL = URL(fileURLWithPath: candidate)
        }
        jobs[id]?.plan = plan
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].localURL = plan.localURL
        }
        start(id: id, resolution: .fail)
    }
}

#if DEBUG
extension SFTPTransferQueue {
    /// Display-only rows: no jobs, filesystem staging, or transfer tasks.
    func installDevelopmentPreview() {
        func sample(_ name: String, upload: Bool, _ state: TransferState) -> Transfer {
            Transfer(id: UUID(), isUpload: upload, name: name,
                     localURL: URL(fileURLWithPath: "/development-preview/" + name), host: "demo.invalid", state: state)
        }
        transfers = [
            sample("archive.zip", upload: false, .active(completed: 4_194_304, total: 10_485_760)),
            sample("README.md", upload: true, .done(bytes: 2048)),
            sample("backup.tar.gz", upload: false, .failed(message: L10n.text("ui.demo.error"), retryable: false)),
        ]
    }
}
#endif
