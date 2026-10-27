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

/// The queue's rows, the questions it asks, and what it runs from.
extension SFTPTransferQueue {
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

    /// Why a transfer a caller waits on failed, in words the system shows
    /// when it reports the error.
    nonisolated struct TransferFailure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
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

    // MARK: Calling the client

    /// A folder's whole tree, up or down.
    static func transferDirectory(
        _ plan: Plan, policy: SFTPTransferEngine.ConflictPolicy, client: any SFTPClient,
        progress: @escaping SFTPTransferEngine.DirectoryProgressHandler
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        if plan.isUpload {
            return try await client.uploadDirectory(
                from: plan.localURL, to: plan.remotePath, policy: policy, progress: progress)
        }
        return try await client.downloadDirectory(
            remotePath: plan.remotePath, to: plan.localURL, policy: policy, progress: progress)
    }

    /// One file, up or down, resuming or replacing as `resolution` says.
    static func transferFile(
        _ plan: Plan, resolution: Resolution, client: any SFTPClient,
        progress: @escaping SFTPTransferEngine.ProgressHandler
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        if plan.isUpload {
            return try await client.upload(
                from: plan.localURL, to: plan.remotePath, policy: resolution.policy,
                partialDisposition: resolution.partialDisposition, progress: progress)
        }
        return try await client.download(
            remotePath: plan.remotePath, to: plan.localURL, policy: resolution.policy,
            partialDisposition: resolution.partialDisposition, progress: progress)
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
}
