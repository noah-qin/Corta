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

// MARK: - Transfers: running

extension SFTPTransferQueue {

    /// A failed row outlives Change Host, and its Retry ran on whichever
    /// machine the browser was on by then: a file queued for one host went to
    /// another. It runs only where the row says it goes.
    func runsHere(_ id: UUID) -> Bool {
        guard let job = jobs[id], job.host != host else { return jobs[id] != nil }
        jobs[id] = nil
        setState(
            id,
            .failed(
                message: L10n.format("sftp.error.connectionLost", job.host),
                retryable: false))
        return false
    }

    func start(id: UUID, resolution: Resolution) {
        guard let job = jobs[id], let client, runsHere(id) else { return }
        let plan = job.plan
        let run = UUID()
        jobs[id]?.resolution = resolution
        jobs[id]?.run = run
        jobs[id]?.preparation = nil
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
                    let receipt = try await Self.transferDirectory(
                        plan, policy: resolution.policy, client: client
                    ) { [weak self] progress in
                        guard pacer.admits() else { return }
                        Task { @MainActor [weak self] in
                            self?.applyDirectoryProgress(progress, to: id)
                        }
                    }
                    guard jobs[id]?.run == run else { return }
                    finishDirectory(id: id, receipt: receipt, isUpload: plan.isUpload)
                    return
                }
                let receipt = try await Self.transferFile(
                    plan, resolution: resolution, client: client, progress: progress)
                guard jobs[id]?.run == run else { return }
                finish(id: id, receipt: receipt, isUpload: plan.isUpload)
            } catch {
                guard jobs[id]?.run == run else { return }
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
                    receipt.skipped.prefix(3).map { SFTPBrowserModel.peerText($0.relativePath, limit: 256) }
                        .joined(separator: ", ")))
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
        // Whatever stopped it once the user had asked it to stop.
        let wasCancelling = transfers.first { $0.id == id }?.state == .cancelling
        switch error {
        case .cancelled:
            setState(id, .cancelled(partialKept: resumable))
        case _ where wasCancelling:
            setState(id, .cancelled(partialKept: resumable))
        default:
            setState(
                id,
                .failed(
                    message: SFTPBrowserModel.errorMessage(error, host: host ?? ""),
                    // Someone waited on this one and has had their answer: a
                    // drag's destination has been told it failed, and its folder
                    // has gone. Drag the file again instead.
                    retryable: error.isRetryableTransportFailure && finishHandlers[id] == nil))
        }
    }

    func setState(_ id: UUID, _ state: TransferState) {
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
    /// pre-flight has no task yet: what it was asking is stopped, and it is
    /// never started. One that does not stop in `cancellingTimeout` is settled
    /// without it, and is heard from again only if it did finish.
    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].state {
        case .queued, .active:
            guard let task = jobs[id]?.task else {
                jobs[id]?.preparation?.cancel()
                jobs[id] = nil
                conflictPrompts.removeAll { $0.transferID == id }
                setState(id, .cancelled(partialKept: false))
                return
            }
            transfers[index].state = .cancelling
            task.cancel()
            let run = jobs[id]?.run
            let timeout = cancellingTimeout
            Task { [weak self] in
                try? await Task.sleep(for: timeout, clock: .suspending)
                guard let self, self.jobs[id]?.run == run,
                    self.transfers.first(where: { $0.id == id })?.state == .cancelling
                else { return }
                self.fail(id: id, error: .cancelled)
            }
        default:
            return
        }
    }

    /// Retries a row that offers it (`Transfer.canRetry`): under the same
    /// resolution it ran with, so a resume run's kept partial makes the retry
    /// continue where it stopped rather than start over; or, when it never got
    /// as far as running, from its pre-flight.
    func retryTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].canRetry,
            client != nil, let job = jobs[id]
        else { return }
        transfers[index].state = .queued
        transfers[index].sampleTime = nil
        transfers[index].bytesPerSecond = nil
        if let resolution = job.resolution {
            start(id: id, resolution: resolution)
        } else {
            jobs[id]?.preparation = Task { await preflight(id: id) }
        }
    }
}
