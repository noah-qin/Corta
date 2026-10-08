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

import Darwin
import CoreServices
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
        public var sourceModificationTime: UInt32?

        public init(
            destinationExists: Bool,
            partialSize: UInt64?,
            sourceSize: UInt64?,
            sourceModificationTime: UInt32?
        ) {
            self.destinationExists = destinationExists
            self.partialSize = partialSize
            self.sourceSize = sourceSize
            self.sourceModificationTime = sourceModificationTime
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

    // MARK: - Partial naming

    /// The partial file's suffix. One fixed name, not one per process: a
    /// resume has to find the partial an *earlier* run left behind, and a
    /// pid in the name would mean nothing survives a relaunch — that partial
    /// would be neither resumed nor cleaned up, on either side. Two live
    /// transfers to one destination never share it: `SFTPDestinationLocks`
    /// serialises them in this process, and a transfer that starts from
    /// zero removes the name and creates its own file exclusively, so
    /// another process's open handle keeps writing a file nobody commits.
    public static let partialSuffix = ".corta-part"

    /// The partial path for a destination, local or remote — the rule is
    /// the same on both sides.
    public static func partialPath(for destination: String) -> String {
        destination + partialSuffix
    }

    // MARK: - Directory operations

    /// The whole directory: READDIR batches until the server answers EOF.
    public func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        let session = self.session
        let handle = try await session.openDirectory(path: path)
        var entries: [SFTPEntry] = []
        var retainedBytes = 0
        do throws(SFTPError) {
            while true {
                let batch = try await session.readDirectory(handle: handle)
                if batch.isEmpty { break }
                guard entries.count <= configuration.maximumDirectoryEntries,
                    batch.count <= configuration.maximumDirectoryEntries - entries.count
                else { throw SFTPError.protocolViolation("directory entry limit exceeded") }
                // Charge retained strings and extension objects before append.
                // The count cap also bounds empty entries and array overhead.
                for entry in batch {
                    func charge(_ count: Int) throws(SFTPError) {
                        guard retainedBytes <= configuration.maximumDirectoryBytes,
                            count <= configuration.maximumDirectoryBytes - retainedBytes
                        else { throw .protocolViolation("directory byte limit exceeded") }
                        retainedBytes += count
                    }
                    try charge(128)
                    try charge(entry.filename.count)
                    try charge(entry.longname.count)
                    for item in entry.attributes.extended {
                        try charge(32)
                        try charge(item.name.count)
                        try charge(item.data.count)
                    }
                }
                entries.append(contentsOf: batch)
            }
        } catch {
            // A listing that failed mid-way still owes the server a CLOSE.
            await cleanUpRemote { try? await session.close(handle) }
            throw error
        }
        try await session.close(handle)
        return entries
    }

    public func makeDirectory(
        path: String, attributes: SFTPAttributes = .init()
    ) async throws(SFTPError) {
        try await session.makeDirectory(path: path, attributes: attributes)
    }

    public func remove(path: String) async throws(SFTPError) {
        try await session.remove(path: path)
    }

    public func removeDirectory(path: String) async throws(SFTPError) {
        try await session.removeDirectory(path: path)
    }

    public func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        try await session.rename(from: oldPath, to: newPath)
    }

    public func stat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await session.stat(path: path)
    }

    public func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await session.lstat(path: path)
    }

    /// Filesystem capacity, or `nil` when the server does not support
    /// `statvfs@openssh.com` — reported unavailable, never guessed.
    public func volumeInfo(path: String = "/") async throws(SFTPError) -> SFTPVolumeInfo? {
        try await session.volumeInfo(path: path)
    }

    // MARK: - Transfers

    private struct LocalPartialIdentity: Equatable, Sendable {
        let device: dev_t
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

    // MARK: - Download

    private func downloadOnce(
        remotePath: String,
        destinationPath: String,
        policy: ConflictPolicy,
        partialDisposition: PartialDisposition,
        progress: ProgressHandler?,
        session: SFTPSession,
        ownedPartial: borrowing Mutex<LocalPartialIdentity?>
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        let sourceAttributes = try await session.stat(path: remotePath)
        if let limit = configuration.maximumDownloadBytes, let size = sourceAttributes.size,
            size > limit
        {
            throw .localIOFailed(operation: "download size limit", code: EFBIG)
        }
        let partialPath = Self.partialPath(for: destinationPath)
        let destinationExists = FileManager.default.fileExists(atPath: destinationPath)
        let partialInfo = localFileInfo(partialPath)

        var conflict = SFTPConflict(
            destinationExists: destinationExists,
            partialSize: partialInfo?.size,
            sourceSize: sourceAttributes.size,
            sourceModificationTime: sourceAttributes.modificationTime)
        var partialStat = Darwin.stat()
        if let identity = ownedPartial.withLock({ $0 }), Darwin.lstat(partialPath, &partialStat) == 0 {
            conflict.partialIsOwned = identity == LocalPartialIdentity(
                device: partialStat.st_dev, inode: partialStat.st_ino)
        }
        let resolution = try resolve(policy: policy, conflict: conflict, destinationPath: destinationPath)

        // Resume validation: the partial is trustworthy only if the source
        // still has the size and mtime the partial recorded in its own
        // mtime when the interrupted transfer started. Otherwise it is a
        // fragment of a different file and the transfer restarts at zero.
        var offset: UInt64 = 0
        if resolution == .resume, let partial = partialInfo {
            let sourceUnchanged = sourceAttributes.modificationTime == partial.modificationSeconds
                && (sourceAttributes.size.map { $0 >= partial.size } ?? true)
            if sourceUnchanged { offset = partial.size }
        }

        // Remote first: a refused OPEN must leave no local partial behind,
        // and nothing open to leak.
        let handle = try await session.open(path: remotePath, flags: .read)
        // A transfer from zero gets a file of its own: the old partial's
        // name is removed and a new one created exclusively, so whoever
        // still holds the old one open writes into a file nothing commits,
        // never into this transfer's.
        if offset == 0, partialInfo != nil { Darwin.unlink(partialPath) }
        let descriptor = Darwin.open(
            partialPath, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW
                | (offset == 0 ? O_EXCL : 0), 0o600)
        guard descriptor >= 0 else {
            let code = errno
            await cleanUpRemote { try? await session.close(handle) }
            if code == EEXIST { throw .destinationConflict(path: partialPath) }
            throw SFTPError.localIOFailed(operation: "open", code: code)
        }

        // Resumed partials from older builds also become private before use.
        // A volume without ACLs (exFAT, FAT, some SMB shares) answers
        // ENOTSUP: it has no inherited ACL to clear, and refusing it would
        // make every download to a USB stick fail.
        let emptyACL = acl_init(0)
        var aclResult = emptyACL.map { acl_set_fd_np(descriptor, $0, ACL_TYPE_EXTENDED) } ?? -1
        if aclResult != 0, errno == ENOTSUP || errno == EOPNOTSUPP { aclResult = 0 }
        if let emptyACL { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard aclResult == 0, Darwin.fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            await cleanUpRemote { try? await session.close(handle) }
            throw SFTPError.localIOFailed(operation: "private download permissions", code: code)
        }
        var openedStat = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedStat) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            await cleanUpRemote { try? await session.close(handle) }
            throw .localIOFailed(operation: "fstat partial", code: code)
        }
        ownedPartial.withLock {
            $0 = LocalPartialIdentity(device: openedStat.st_dev, inode: openedStat.st_ino)
        }

        let abort = AbortFlag()
        // Closed exactly once: a failure after the success path's close
        // must not close the number again — by then it may be another file's.
        var descriptorOpen = true
        do {
            let receipt = try await withTaskCancellationHandler {
                try await self.pipeDownload(
                    session: session, remotePath: remotePath, handle: handle, descriptor: descriptor,
                    offset: offset, total: sourceAttributes.size,
                    sourceModificationSeconds: sourceAttributes.modificationTime,
                    progress: progress, abort: abort)
            } onCancel: {
                abort.set()
            }
            Darwin.close(descriptor)
            descriptorOpen = false
            try await session.close(handle)
            // A source that changed while it was read is not the file that
            // was asked for: what landed may mix two versions, or stop short.
            let after = try await session.stat(path: remotePath)
            if after.size != sourceAttributes.size
                || after.modificationTime != sourceAttributes.modificationTime
            {
                throw SFTPError.sourceChanged(path: remotePath)
            }
            // On the partial, so the file appears at its name already marked:
            // marked after the rename, it sat there unmarked for a moment.
            if configuration.quarantinesDownloads { Self.markQuarantined(partialPath) }
            // Commit: rename over the destination atomically — or, when the
            // policy forbids replacing it, only if it is still absent: a file
            // that appeared since the check is not ours to overwrite.
            let renamed =
                resolution == .fail
                ? renamex_np(partialPath, destinationPath, UInt32(RENAME_EXCL))
                : Darwin.rename(partialPath, destinationPath)
            guard renamed == 0 else {
                let code = errno
                if code == EEXIST { throw SFTPError.destinationConflict(path: destinationPath) }
                throw SFTPError.localIOFailed(operation: "rename", code: code)
            }
            return SFTPTransferReceipt(
                bytesTransferred: receipt, resumedFromOffset: offset, attempts: 0)
        } catch {
            if descriptorOpen { Darwin.close(descriptor) }
            // Attempt CLOSE independently of caller cancellation, with a
            // deadline so an uncooperative peer cannot retain this slot.
            await cleanUpRemote { try? await session.close(handle) }
            cleanUpPartial(
                partialPath, disposition: partialDisposition,
                keepForResume: resolution == .resume)
            if let sftpError = error as? SFTPError, !abort.isSet { throw sftpError }
            throw .cancelled
        }
    }

    /// The windowed block fetch: up to `pipelineDepth` READs in flight,
    /// each completed block written at its offset with `pwrite` before the
    /// next window slot opens. Returns bytes moved in this run.
    private func pipeDownload(
        session: SFTPSession,
        remotePath: String,
        handle: SFTPHandle,
        descriptor: Int32,
        offset: UInt64,
        total: UInt64?,
        sourceModificationSeconds: UInt32?,
        progress: ProgressHandler?,
        abort: AbortFlag
    ) async throws(SFTPError) -> UInt64 {
        var nextOffset = offset
        var completed = offset
        var moved: UInt64 = 0
        var endOfFile = false
        var pending: [(offset: UInt64, length: Int, task: Task<[UInt8], any Error>)] = []
        pending.reserveCapacity(configuration.pipelineDepth)
        defer { for item in pending { item.task.cancel() } }

        while !endOfFile {
            if abort.isSet || Task.isCancelled {
                for item in pending { item.task.cancel() }
                throw SFTPError.cancelled
            }
            while pending.count < configuration.pipelineDepth {
                if let total, nextOffset >= total { break }
                let remaining = total.map { $0 - nextOffset }
                let length = UInt32(min(UInt64(configuration.blockSize), remaining ?? UInt64.max))
                if length == 0 { break }
                let requestOffset = nextOffset
                let task = Task<[UInt8], any Error> {
                    try await session.read(handle: handle, offset: requestOffset, length: length)
                }
                pending.append((offset: requestOffset, length: Int(length), task: task))
                nextOffset += UInt64(length)
            }
            guard !pending.isEmpty else { break }
            let first = pending.removeFirst()
            let data = try await taskValue(first.task)
            if data.isEmpty {
                // The server answered EOF. Before the size the file had when
                // the transfer began, it means the file shrank under the
                // transfer: committing what arrived would replace the
                // destination with a truncated copy and call it done.
                if let total, first.offset < total {
                    throw SFTPError.sourceChanged(path: remotePath)
                }
                endOfFile = true
                for item in pending { item.task.cancel() }
                break
            }
            // More than was asked is no reply to the READ: written, it ran
            // past the stated size and under the next block.
            guard data.count <= first.length else {
                throw SFTPError.protocolViolation("READ reply longer than requested")
            }
            if let limit = configuration.maximumDownloadBytes,
                first.offset + UInt64(data.count) > limit
            {
                throw SFTPError.localIOFailed(operation: "download size limit", code: EFBIG)
            }
            try writeAll(descriptor: descriptor, bytes: data, at: first.offset)
            // The partial's mtime is the resume-validation record, but
            // every pwrite bumps it — restamp after each block so an
            // interruption at any point leaves a self-validating partial.
            if let seconds = sourceModificationSeconds {
                stampModificationTime(descriptor, seconds: seconds)
            }
            moved += UInt64(data.count)
            completed = first.offset + UInt64(data.count)
            progress?(SFTPTransferProgress(completedBytes: completed, totalBytes: total))
            if data.count < first.length {
                // OpenSSH's server reads short only at end of file, but the
                // protocol lets any server return less than asked — some cap
                // a READ below the block size — and taking that for the end
                // committed a truncated file as a success. The rest of the
                // window was asked past a point the server has not reached:
                // drop it and ask again from here. Only the server's EOF, or
                // the size the file had, ends the transfer.
                for item in pending { item.task.cancel() }
                pending.removeAll()
                nextOffset = completed
            }
        }
        return moved
    }

    // MARK: - Upload

    /// What identifies an upload's source while it is read: the file the
    /// descriptor names, and the size and mtime it had when it was opened.
    struct LocalSourceIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: UInt64
        let modificationSeconds: Int
        let modificationNanoseconds: Int

        init(_ info: Darwin.stat) {
            device = info.st_dev
            inode = info.st_ino
            size = UInt64(clamping: info.st_size)
            modificationSeconds = Int(info.st_mtimespec.tv_sec)
            modificationNanoseconds = Int(info.st_mtimespec.tv_nsec)
        }

        /// The mtime as SFTP version 3 carries it: whole seconds.
        var sftpModificationTime: UInt32 { UInt32(clamping: modificationSeconds) }
    }

    /// Which source each remote upload partial was written from, for the
    /// partials this process wrote. Every WRITE moves a real server's mtime
    /// on, so the stamp the upload set when it opened the partial is gone
    /// by the time a transport failure or a cancel interrupts it; the
    /// record is what lets the retry — or the user's next attempt, until
    /// relaunch — recognise its own partial. Across a relaunch the stamp
    /// the cleanup restores is the evidence instead.
    private static let uploadResumeRecords = Mutex<[String: LocalSourceIdentity]>([:])

    private func uploadOnce(
        sourcePath: String,
        remotePath: String,
        policy: ConflictPolicy,
        partialDisposition: PartialDisposition,
        progress: ProgressHandler?,
        session: SFTPSession
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        // The descriptor, not the name, is what is uploaded: its size and
        // mtime at open are the ones the transfer is checked against.
        let descriptor = Darwin.open(sourcePath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw SFTPError.localIOFailed(operation: code == ENOENT ? "stat" : "open", code: code)
        }
        defer { Darwin.close(descriptor) }
        var openedStat = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedStat) == 0 else {
            throw SFTPError.localIOFailed(operation: "fstat", code: errno)
        }
        let source = LocalSourceIdentity(openedStat)
        let sourceSize = source.size
        let sourceMTime = source.sftpModificationTime

        let partialPath = Self.partialPath(for: remotePath)
        let recordKey = remoteClaim(partialPath)
        let destinationAttributes = try? await session.lstat(path: remotePath)
        let partialAttributes = try? await session.lstat(path: partialPath)

        let resolution = try resolve(
            policy: policy,
            conflict: SFTPConflict(
                destinationExists: destinationAttributes != nil,
                partialSize: partialAttributes?.size,
                sourceSize: sourceSize,
                sourceModificationTime: sourceMTime),
            destinationPath: remotePath)

        var offset: UInt64 = 0
        if resolution == .resume, let partial = partialAttributes, let partialSize = partial.size,
            sourceSize >= partialSize
        {
            // The remote partial recorded the local source's mtime in its
            // own when the interrupted upload was cleaned up (see below), or
            // this process remembers writing it from this very source.
            let recorded = Self.uploadResumeRecords.withLock { $0[recordKey] }
            if partial.modificationTime == sourceMTime || recorded == source {
                offset = partialSize
            }
        }

        var flags: SFTPOpenFlags = [.write]
        if offset == 0 {
            // From zero, the partial is this transfer's own file: the old
            // name goes, and the new one is created exclusively. A handle
            // another process still holds then writes into a file nobody
            // commits — never into this one after it is renamed into place.
            if partialAttributes != nil { try await session.remove(path: partialPath) }
            flags.formUnion([.create, .exclude])
        }
        var openedHandle: SFTPHandle?
        var openFailure: SFTPError?
        do throws(SFTPError) {
            openedHandle = try await session.open(path: partialPath, flags: flags)
        } catch {
            openFailure = error
        }
        guard let handle = openedHandle else {
            let failure = openFailure ?? .cancelled
            // OpenSSH answers an exclusive create of an existing name with
            // a plain FAILURE: someone else made the partial since the check.
            if offset == 0, failure.isPlainServerFailure {
                throw .destinationConflict(path: partialPath)
            }
            throw failure
        }
        Self.uploadResumeRecords.withLock { $0[recordKey] = source }
        try? await session.fsetStat(
            handle: handle, attributes: SFTPAttributes(modificationTime: sourceMTime))

        let abort = AbortFlag()
        var handleOpen = true
        do {
            let moved = try await withTaskCancellationHandler {
                try await self.pipeUpload(
                    session: session, handle: handle, descriptor: descriptor,
                    sourcePath: sourcePath, offset: offset, total: sourceSize,
                    progress: progress, abort: abort)
            } onCancel: {
                abort.set()
            }
            try Self.verifySourceUnchanged(descriptor: descriptor, path: sourcePath, opened: source)
            handleOpen = false
            try await session.close(handle)
            try await commitUpload(
                session: session, partialPath: partialPath, destinationPath: remotePath,
                mayReplace: resolution != .fail)
            Self.uploadResumeRecords.withLock { $0[recordKey] = nil }
            return SFTPTransferReceipt(
                bytesTransferred: moved, resumedFromOffset: offset, attempts: 0)
        } catch {
            let failure = error as? SFTPError
            if let failure, failure.isIncompleteReplacement {
                // The partial may be the only copy of the new content now;
                // the error names where both copies are.
                Self.uploadResumeRecords.withLock { $0[recordKey] = nil }
                throw failure
            }
            if handleOpen { await cleanUpRemote { try? await session.close(handle) } }
            if Self.keepsPartial(partialDisposition, keepForResume: resolution == .resume) {
                // Every WRITE moved the partial's mtime; put the source's
                // back so the partial validates itself after a relaunch.
                await cleanUpRemote {
                    try? await session.setStat(
                        path: partialPath, attributes: SFTPAttributes(modificationTime: sourceMTime))
                }
            } else {
                Self.uploadResumeRecords.withLock { $0[recordKey] = nil }
                await cleanUpRemote { try? await session.remove(path: partialPath) }
            }
            if let failure, !abort.isSet { throw failure }
            throw .cancelled
        }
    }

    /// A source is uploaded as it was when it was opened, or not at all:
    /// the same file at the same name, the same size, the same mtime. A
    /// file that was truncated, grew, was rewritten or was replaced while
    /// it was read produced an upload that is none of its versions.
    static func verifySourceUnchanged(
        descriptor: Int32, path: String, opened: LocalSourceIdentity
    ) throws(SFTPError) {
        var now = Darwin.stat()
        guard Darwin.fstat(descriptor, &now) == 0 else {
            throw .localIOFailed(operation: "fstat", code: errno)
        }
        var named = Darwin.stat()
        guard LocalSourceIdentity(now) == opened, fstatat(AT_FDCWD, path, &named, 0) == 0,
            named.st_dev == opened.device, named.st_ino == opened.inode
        else { throw .sourceChanged(path: path) }
    }

    /// The write side of the window: `pread` a block locally, send WRITE,
    /// keep up to `pipelineDepth` unanswered.
    private func pipeUpload(
        session: SFTPSession,
        handle: SFTPHandle,
        descriptor: Int32,
        sourcePath: String,
        offset: UInt64,
        total: UInt64,
        progress: ProgressHandler?,
        abort: AbortFlag
    ) async throws(SFTPError) -> UInt64 {
        var nextOffset = offset
        var moved: UInt64 = 0
        var sourceDrained = offset >= total
        var pending: [(offset: UInt64, length: Int, task: Task<Void, any Error>)] = []
        pending.reserveCapacity(configuration.pipelineDepth)
        defer { for item in pending { item.task.cancel() } }

        while !sourceDrained || !pending.isEmpty {
            if abort.isSet || Task.isCancelled {
                for item in pending { item.task.cancel() }
                throw SFTPError.cancelled
            }
            while pending.count < configuration.pipelineDepth, !sourceDrained {
                let length = min(UInt64(configuration.blockSize), total - nextOffset)
                let requestOffset = nextOffset
                let block = try readAll(descriptor: descriptor, count: Int(length), at: requestOffset)
                // A short or empty local read before the size the source
                // had at open means it shrank mid-transfer. Uploading what
                // was read would replace the destination with a truncated
                // copy and report it complete.
                guard block.count == Int(length) else {
                    throw SFTPError.sourceChanged(path: sourcePath)
                }
                let task = Task<Void, any Error> {
                    try await session.write(handle: handle, offset: requestOffset, data: block)
                }
                pending.append((offset: requestOffset, length: block.count, task: task))
                nextOffset += UInt64(block.count)
                if nextOffset >= total { sourceDrained = true }
            }
            guard !pending.isEmpty else { break }
            let first = pending.removeFirst()
            _ = try await taskValue(first.task)
            moved += UInt64(first.length)
            progress?(SFTPTransferProgress(
                completedBytes: first.offset + UInt64(first.length), totalBytes: total))
        }
        return moved
    }

    /// RENAME the partial over the destination. When the policy allows
    /// replacing it, `posix-rename` is used if the server advertises it.
    /// Otherwise version 3's RENAME fails against an existing destination,
    /// and the replacement is done in steps that never leave the old
    /// content without a name: the destination is renamed aside, the
    /// partial renamed into place, and only then is the old copy removed.
    /// A failure in between renames the old copy back. Only when that,
    /// too, fails does the commit end with the two copies apart, and then
    /// `.replaceIncomplete` says where each of them is.
    ///
    /// When the policy does not allow replacing (`.fail`), version 3's
    /// RENAME is the point: it refuses a destination that appeared after
    /// the check, where `posix-rename` replaced it.
    private func commitUpload(
        session: SFTPSession,
        partialPath: String,
        destinationPath: String,
        mayReplace: Bool
    ) async throws(SFTPError) {
        if mayReplace, try await session.posixRename(from: partialPath, to: destinationPath) {
            return
        }
        let refusal: SFTPError
        do throws(SFTPError) {
            try await session.rename(from: partialPath, to: destinationPath)
            return
        } catch {
            refusal = error
        }
        // OpenSSH's server answers SSH_FX_FAILURE for an existing
        // destination; the code is not checked because draft-02 assigns no
        // specific one. Anything else, or a policy that keeps the
        // destination, is the answer.
        guard mayReplace, case .server = refusal else { throw refusal }

        let aside = destinationPath + ".corta-old-" + String(UInt32.random(in: .min ... .max), radix: 16)
        do throws(SFTPError) {
            // Version 3 RENAME refuses an existing name, so this never
            // displaces anything; a destination that is not there fails
            // here, and the first refusal was about something else.
            try await session.rename(from: destinationPath, to: aside)
        } catch {
            throw refusal
        }
        do throws(SFTPError) {
            try await session.rename(from: partialPath, to: destinationPath)
        } catch {
            do throws(SFTPError) {
                try await session.rename(from: aside, to: destinationPath)
            } catch {
                throw .replaceIncomplete(
                    destination: destinationPath, previousCopy: aside, newCopy: partialPath)
            }
            throw error
        }
        // The new content is in place; the old copy is only clutter now,
        // and a failed REMOVE leaves it under a name that says what it is.
        try? await session.remove(path: aside)
    }

    private static func keepsPartial(_ disposition: PartialDisposition, keepForResume: Bool) -> Bool {
        switch disposition {
        case .keepForResume: true
        case .remove: false
        case .automatic: keepForResume
        }
    }

    // MARK: - Policy

    private func resolve(
        policy: ConflictPolicy,
        conflict: SFTPConflict,
        destinationPath: String
    ) throws(SFTPError) -> ConflictResolution {
        let resolution: ConflictResolution
        switch policy {
        case .fail: resolution = .fail
        case .overwrite: resolution = .overwrite
        // `.resume` keeps its meaning even with no partial present: the
        // transfer starts at zero either way, but the resolution is what
        // decides whether an interrupted run's partial is kept for a later
        // resume — a caller who asked for resume wants that.
        case .resume: resolution = .resume
        case .decide(let decide): resolution = decide(conflict)
        }
        if resolution == .fail, conflict.destinationExists {
            throw .destinationConflict(path: destinationPath)
        }
        // A suffix alone does not prove a file is our interrupted transfer.
        // Only an explicit overwrite/resume decision may reuse one.
        if resolution == .fail, conflict.partialSize != nil {
            throw .destinationConflict(path: Self.partialPath(for: destinationPath))
        }
        return resolution
    }

    // MARK: - Partial cleanup

    /// Local partial removal, synchronous (download path).
    private func cleanUpPartial(
        _ path: String,
        disposition: PartialDisposition,
        keepForResume: Bool
    ) {
        let keep: Bool
        switch disposition {
        case .keepForResume: keep = true
        case .remove: keep = false
        case .automatic: keep = keepForResume
        }
        if !keep { Darwin.unlink(path) }
    }

    /// Only failure cleanup ignores the parent cancellation. The deadline
    /// cancels the request itself; SFTPSession resumes cancelled waiters.
    private func cleanUpRemote(_ operation: @escaping @Sendable () async -> Void) async {
        let cleanup = Task { await operation() }
        let timeout = configuration.cleanupTimeout
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            cleanup.cancel()
        }
        await cleanup.value
        timer.cancel()
    }

    // MARK: - Local filesystem helpers

    /// Size and mtime of a local file, or `nil` when it does not exist.
    /// (`stat(2)` by hand is awkward in Swift — the `Darwin.stat` struct
    /// shadows the function — and `FileManager` answers both questions at
    /// once; the real I/O errors still surface from `open`/`pread`.)
    private func localFileInfo(_ path: String) -> (size: UInt64, modificationSeconds: UInt32)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        let date = attributes[.modificationDate] as? Date
        return (
            size.uint64Value,
            UInt32(clamping: Int(date?.timeIntervalSince1970 ?? 0))
        )
    }

    /// Awaits a pipeline task, re-embedding its typed error: the toolchain's
    /// `Task` has no typed-`Failure` initializer, so the block runs under
    /// `any Error` and is narrowed back here.
    private func taskValue<Success>(
        _ task: Task<Success, any Error>
    ) async throws(SFTPError) -> Success {
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch let error as SFTPError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .protocolViolation("\(error)")
        }
    }

    /// Sets the file's mtime without touching its atime — the partial's
    /// mtime is the resume-validation record, nothing else.
    private func stampModificationTime(_ descriptor: Int32, seconds: UInt32) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: 0),
        ]
        _ = futimens(descriptor, &times)
    }

    private func writeAll(descriptor: Int32, bytes: [UInt8], at offset: UInt64) throws(SFTPError) {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.pwrite(
                    descriptor, buffer.baseAddress! + written, bytes.count - written,
                    off_t(offset) + off_t(written))
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw SFTPError.localIOFailed(operation: "pwrite", code: errno)
        }
    }

    private func readAll(descriptor: Int32, count: Int, at offset: UInt64) throws(SFTPError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let n = bytes.withUnsafeMutableBytes { buffer -> Int in
                Darwin.pread(
                    descriptor, buffer.baseAddress! + read, count - read,
                    off_t(offset) + off_t(read))
            }
            if n > 0 {
                read += n
                continue
            }
            if n == 0 { break }  // local EOF: source shrank mid-read
            if errno == EINTR { continue }
            throw SFTPError.localIOFailed(operation: "pread", code: errno)
        }
        bytes.removeSubrange(read...)
        return bytes
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
