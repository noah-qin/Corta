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

import CoreServices
import Darwin
import Foundation
import Synchronization

/// File transfer and directory operations over an `SFTPSession`.
///
/// What the engine guarantees:
///
/// - **Atomic destinations.** A download writes `name.corta-part`
///   next to the destination and `rename(2)`s it over the target only when
///   complete; an upload does the same with a remote temp file and RENAME
///   (`posix-rename@openssh.com` when the server advertises it, because
///   version 3's plain RENAME fails against an existing destination — the
///   fallback renames the old file aside, the new one into place, and only
///   then removes the old one, renaming it back if the second step fails;
///   not atomic, but never without a copy of the old content). An
///   interrupted transfer therefore never leaves a silently-accepted
///   partial file at the destination name.
///
/// - **One transfer per destination.** Transfers to the same path wait
///   for each other (`SFTPDestinationLocks`), and a transfer from zero
///   creates its partial exclusively, so nothing writes into a file
///   another transfer has committed.
///
/// - **The source as it was.** A source that shrinks, grows, is rewritten
///   or replaced while it is read fails the transfer with `.sourceChanged`
///   instead of committing a copy that is none of its versions.
///
/// - **Resumable partials.** The partial file's own mtime stores the
///   *source's* mtime at the moment the transfer started — restamped after
///   every block of a download, and when an interrupted upload is cleaned
///   up, because every WRITE moves a server's mtime on. Resuming takes
///   the partial's size as the offset and validates the endpoints: if the
///   source's size or mtime no longer matches what the partial recorded,
///   the partial is stale and the transfer restarts from zero instead of
///   splicing two different files together.
///
/// - **Typed failures.** Everything throws `SFTPError`. A server STATUS is
///   a definitive answer and is never retried; only transport-class
///   failures are retried, bounded, with backoff — and only when a
///   `reconnect` closure was supplied, because re-running ssh (and its
///   authentication) is the app layer's job, not the engine's.
///
/// - **Bounded concurrency.** At most `maxConcurrentTransfers` transfers
///   run at once, admitted FIFO; each is cancellable independently via
///   `Task` cancellation. Cancellation aborts the transfer: outstanding
///   requests are abandoned, the server is sent CLOSE, and the partial is
///   kept or removed per policy.
///
/// The engine holds the session weakly to nothing — it owns it. When a
/// reconnect closure installs a fresh session after a transport failure,
/// later directory operations use the fresh one.
public final class SFTPTransferEngine: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// How many transfers run concurrently. Two overlaps a download
        /// with an upload without multiplying ssh channels' windows.
        public var maxConcurrentTransfers = 2

        /// Blocks in flight per transfer. Each block is one SFTP request,
        /// so this is also bounded by the session's own window.
        public var pipelineDepth = 16

        /// Bytes per READ/WRITE request. OpenSSH's *message* cap is
        /// 256 KiB, header included, so a 256 KiB data block made every
        /// WRITE a "bad message" that ended the session (found against the
        /// real `sftp-server`); 32 KiB is what OpenSSH's own client sends,
        /// and with `pipelineDepth` requests in flight it is not the
        /// throughput bound.
        public var blockSize = 32 * 1024

        /// Total attempts per transfer, the first included. Only
        /// transport-class failures consume attempts.
        public var maximumAttempts = 3

        public var initialBackoff: Duration = .milliseconds(200)
        public var maximumBackoff: Duration = .seconds(2)

        /// Aggregate bounds, in addition to the codec's per-frame limit.
        /// A limit failure returns an error, never a partial listing/tree.
        public var maximumDirectoryEntries = 100_000
        public var maximumDirectoryBytes = 32 * 1024 * 1024
        public var maximumTreeEntries = 100_000
        public var maximumTreePathBytes = 16 * 1024 * 1024
        public var maximumTreeDepth = 128

        /// Failed/cancelled transfers cannot wait forever for peer cleanup.
        public var cleanupTimeout: Duration = .seconds(1)

        /// Marks each committed download with `com.apple.quarantine`, as a
        /// browser does: a remote `.app`, `.command` or `.pkg` opened from
        /// Finder then gets Gatekeeper's first-open check instead of skipping
        /// it. Through LaunchServices, never `LSFileQuarantineEnabled`, which
        /// every shell the app spawns would inherit.
        public var quarantinesDownloads = false

        /// The most one download may write; `nil` for no limit. A server
        /// states a file's size, or leaves it out and answers READs for as
        /// long as it likes — a stated size over the limit is refused before
        /// OPEN, and bytes past it end the transfer, whatever was stated.
        public var maximumDownloadBytes: UInt64?

        /// What makes a remote path unique across engines: the host the
        /// session reaches. Two engines with the same scope never transfer
        /// to the same remote path at once (`SFTPDestinationLocks`); `nil`
        /// scopes the engine to itself, which still serialises its own
        /// transfers but not another engine's.
        public var destinationScope: String?

        public init() {}
    }

    /// What to do when the destination, or a partial for it, is in the way.
    public enum ConflictPolicy: Sendable {
        /// Fail if the destination exists.
        case fail
        /// Replace the destination.
        case overwrite
        /// Continue a partial if one is present and still matches the
        /// source; otherwise (and when none exists) transfer from zero and
        /// replace the destination.
        case resume
        /// The caller decides per transfer, from what the engine found.
        case decide(@Sendable (SFTPConflict) -> ConflictResolution)
    }

    public enum ConflictResolution: Equatable, Sendable {
        case fail
        case overwrite
        case resume
    }

    /// What the engine found at the destination before starting.
    public struct SFTPConflict: Equatable, Sendable {
        public var destinationExists: Bool
        /// The interrupted partial's size, when one is present.
        public var partialSize: UInt64?
        /// The same inode created/explicitly adopted by this download call,
        /// retained across its transport retries. Never inferred from a name.
        public internal(set) var partialIsOwned = false
        public var sourceSize: UInt64?

        public init(destinationExists: Bool, partialSize: UInt64?, sourceSize: UInt64?) {
            self.destinationExists = destinationExists
            self.partialSize = partialSize
            self.sourceSize = sourceSize
        }
    }

    /// What happens to the partial when a transfer does not complete.
    public enum PartialDisposition: Equatable, Sendable {
        /// Kept when the transfer was running under a resume resolution,
        /// removed otherwise.
        case automatic
        case keepForResume
        case remove
    }

    public struct SFTPTransferProgress: Equatable, Sendable {
        public var completedBytes: UInt64
        /// The source's size; `nil` when the server did not report one.
        public var totalBytes: UInt64?

        public init(completedBytes: UInt64, totalBytes: UInt64?) {
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
        }
    }

    public struct SFTPTransferReceipt: Equatable, Sendable {
        /// Bytes moved by *these* attempts — a resumed transfer's earlier
        /// partial content is not counted again.
        public var bytesTransferred: UInt64
        /// The offset the completed transfer started from.
        public var resumedFromOffset: UInt64
        /// How many attempts it took; 1 means no retry happened.
        public var attempts: Int

        public init(bytesTransferred: UInt64, resumedFromOffset: UInt64, attempts: Int) {
            self.bytesTransferred = bytesTransferred
            self.resumedFromOffset = resumedFromOffset
            self.attempts = attempts
        }
    }

    public typealias ProgressHandler = @Sendable (SFTPTransferProgress) -> Void

    /// Builds a fresh session after a transport failure. The app layer
    /// owns everything this needs — spawning ssh, authentication — and
    /// the engine calls it only between attempts, never mid-flight.
    public typealias ReconnectHandler = @Sendable () async throws -> SFTPSession

    public let configuration: Configuration
    private let currentSession: Mutex<SFTPSession>
    private let reconnect: ReconnectHandler?

    private struct QueueState {
        var running = 0
        var waiters: [(token: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
        var nextToken: UInt64 = 0
    }

    private let queue = Mutex(QueueState())

    /// Test barrier between a full admission window and waiter registration.
    /// Configure before starting transfers.
    var transferAdmissionGate: (@Sendable () -> Void)?

    public init(
        session: SFTPSession,
        reconnect: ReconnectHandler? = nil,
        configuration: Configuration = .init()
    ) {
        self.currentSession = Mutex(session)
        self.reconnect = reconnect
        self.configuration = configuration
    }

    /// The session directory operations currently run against — the
    /// original, or the replacement a reconnect installed.
    public var session: SFTPSession { currentSession.withLock { $0 } }

    // MARK: - Transfers

    struct LocalPartialIdentity: Equatable, Sendable {
        // periphery:ignore - compared by ==, which is how the download's own partial is recognised
        let device: dev_t
        // periphery:ignore - compared by ==, which is how the download's own partial is recognised
        let inode: ino_t
    }

    /// Downloads `remotePath` to `localDestination` atomically: through a
    /// partial file, then `rename(2)` over the destination.
    @discardableResult
    public func download(
        remotePath: String,
        to localDestination: URL,
        policy: ConflictPolicy = .fail,
        partialDisposition: PartialDisposition = .automatic,
        progress: ProgressHandler? = nil
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        // The destination first, then a slot: a transfer waiting its turn
        // for a path must not hold one of the slots other paths need.
        let claim = "local\u{0}" + SFTPDestinationLocks.normalizedLocalPath(localDestination.path)
        try await SFTPDestinationLocks.shared.acquire(claim)
        defer { SFTPDestinationLocks.shared.release(claim) }
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        let ownedPartial = Mutex<LocalPartialIdentity?>(nil)
        return try await withAttempts { (session: SFTPSession) async throws(SFTPError) in
            try await self.downloadOnce(
                remotePath: remotePath, destinationPath: localDestination.path,
                policy: policy, partialDisposition: partialDisposition,
                progress: progress, session: session, ownedPartial: ownedPartial)
        }
    }

    /// Uploads `localSource` to `remotePath` atomically: through a remote
    /// partial file, then RENAME over the destination.
    @discardableResult
    public func upload(
        from localSource: URL,
        to remotePath: String,
        policy: ConflictPolicy = .fail,
        partialDisposition: PartialDisposition = .automatic,
        progress: ProgressHandler? = nil
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        let claim = remoteClaim(remotePath)
        try await SFTPDestinationLocks.shared.acquire(claim)
        defer { SFTPDestinationLocks.shared.release(claim) }
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        return try await withAttempts { (session: SFTPSession) async throws(SFTPError) in
            try await self.uploadOnce(
                sourcePath: localSource.path, remotePath: remotePath,
                policy: policy, partialDisposition: partialDisposition,
                progress: progress, session: session)
        }
    }

    /// The claim key for a remote destination under this engine's scope.
    func remoteClaim(_ remotePath: String) -> String {
        let scope = configuration.destinationScope ?? "engine-\(ObjectIdentifier(self))"
        return "remote\u{0}\(scope)\u{0}" + SFTPDestinationLocks.normalizedRemotePath(remotePath)
    }

    /// Best effort: a volume without extended attributes cannot carry the
    /// mark, and refusing the download over it would help nobody.
    static func markQuarantined(_ path: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Corta",
        ]
        try? url.setResourceValues(values)
    }

    // MARK: - Retry

    /// The attempt loop. A transport-class failure is retried — bounded,
    /// with doubling backoff — only when a reconnect handler exists to
    /// build a fresh channel; without one there is nothing to retry
    /// *with*, and the failure propagates. Server STATUSes, protocol
    /// violations and cancellation are definitive and never retried.
    private func withAttempts(
        _ body: (SFTPSession) async throws(SFTPError) -> SFTPTransferReceipt
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        var attempt = 1
        var backoff = configuration.initialBackoff
        while true {
            do {
                var receipt = try await body(session)
                receipt.attempts = attempt
                return receipt
            } catch let transportFailure where transportFailure.isRetryableTransportFailure {
                guard let reconnect, attempt < configuration.maximumAttempts else {
                    throw transportFailure
                }
                attempt += 1
                do {
                    try await Task.sleep(for: backoff)
                } catch {
                    throw SFTPError.cancelled
                }
                backoff = min(backoff * 2, configuration.maximumBackoff)
                let fresh: SFTPSession
                do {
                    fresh = try await reconnect()
                } catch {
                    // Reconnection is the app layer's ssh spawn; its
                    // failure means the retry policy is exhausted in
                    // practice — surface the original transport failure.
                    throw transportFailure
                }
                currentSession.withLock { $0 = fresh }
            }
        }
    }

    // MARK: - Transfer queue

    /// FIFO admission to `maxConcurrentTransfers` running transfers,
    /// cancellable while queued. The continuation's Bool says whether the
    /// waiter was admitted; on admission the running slot passes directly
    /// to the waiter, so `running` is never touched on the handoff path.
    private func acquireTransferSlot() async throws(SFTPError) {
        if Task.isCancelled { throw .cancelled }
        let fast = queue.withLock { state -> Bool in
            if state.running < configuration.maxConcurrentTransfers {
                state.running += 1
                return true
            }
            return false
        }
        if fast { return }
        transferAdmissionGate?()
        let token = queue.withLock { state -> UInt64 in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let outcome = queue.withLock { state -> Bool? in
                    // Cancellation may precede registration; release may have
                    // opened room since the fast path. Check both atomically.
                    guard !Task.isCancelled else { return false }
                    if state.running < configuration.maxConcurrentTransfers {
                        state.running += 1
                        return true
                    }
                    state.waiters.append((token: token, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            queue.withLock { state in
                if let index = state.waiters.firstIndex(where: { $0.token == token }) {
                    state.waiters.remove(at: index).continuation.resume(returning: false)
                }
            }
        }
        guard admitted else { throw .cancelled }
    }

    private func releaseTransferSlot() {
        queue.withLock { state in
            if !state.waiters.isEmpty {
                // The slot passes to the waiter; the count stays.
                state.waiters.removeFirst().continuation.resume(returning: true)
            } else {
                state.running -= 1
            }
        }
    }
}

/// A lock-protected cancellation flag shared between a transfer and its
/// cancellation handler. (`Task.isCancelled` alone cannot be observed by
/// the transfer loop while it sits inside `await task.value` on a server
/// that never answers — the flag plus child-task cancellation covers both.)
final class AbortFlag: Sendable {
    private let flag = Mutex(false)

    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}
