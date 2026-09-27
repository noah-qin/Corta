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
///   REMOVE+RENAME fallback is documented best-effort, not atomic). An
///   interrupted transfer therefore never leaves a silently-accepted
///   partial file at the destination name.
///
/// - **Resumable partials.** The partial file's own mtime stores the
///   *source's* mtime at the moment the transfer started. Resuming takes
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
    /// transfers to the same destination would be a conflict anyway, so
    /// the pid bought no isolation.
    public static let partialSuffix = ".corta-part"

    /// The partial path for a destination, local or remote — the rule is
    /// the same on both sides.
    public static func partialPath(for destination: String) -> String {
        destination + partialSuffix
    }

    // MARK: - Directory operations

    /// The whole directory: READDIR batches until the server answers EOF.
    public func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        let handle = try await session.openDirectory(path: path)
        var entries: [SFTPEntry] = []
        do {
            while true {
                let batch = try await session.readDirectory(handle: handle)
                if batch.isEmpty { break }
                entries.append(contentsOf: batch)
            }
        } catch {
            // A listing that failed mid-way still owes the server a CLOSE.
            try? await session.close(handle)
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
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        return try await withAttempts { (session: SFTPSession) async throws(SFTPError) in
            try await self.downloadOnce(
                remotePath: remotePath, destinationPath: localDestination.path,
                policy: policy, partialDisposition: partialDisposition,
                progress: progress, session: session)
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
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        return try await withAttempts { (session: SFTPSession) async throws(SFTPError) in
            try await self.uploadOnce(
                sourcePath: localSource.path, remotePath: remotePath,
                policy: policy, partialDisposition: partialDisposition,
                progress: progress, session: session)
        }
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
        session: SFTPSession
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        let sourceAttributes = try await session.stat(path: remotePath)
        let partialPath = Self.partialPath(for: destinationPath)
        let destinationExists = FileManager.default.fileExists(atPath: destinationPath)
        let partialInfo = localFileInfo(partialPath)

        let resolution = try resolve(
            policy: policy,
            conflict: SFTPConflict(
                destinationExists: destinationExists,
                partialSize: partialInfo?.size,
                sourceSize: sourceAttributes.size,
                sourceModificationTime: sourceAttributes.modificationTime),
            destinationPath: destinationPath)

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

        let descriptor = Darwin.open(
            partialPath, O_WRONLY | O_CREAT | (offset == 0 ? O_TRUNC : 0), 0o644)
        guard descriptor >= 0 else {
            throw SFTPError.localIOFailed(operation: "open", code: errno)
        }

        let handle = try await session.open(path: remotePath, flags: .read)
        let abort = AbortFlag()
        do {
            let receipt = try await withTaskCancellationHandler {
                try await self.pipeDownload(
                    session: session, handle: handle, descriptor: descriptor,
                    offset: offset, total: sourceAttributes.size,
                    sourceModificationSeconds: sourceAttributes.modificationTime,
                    progress: progress, abort: abort)
            } onCancel: {
                abort.set()
            }
            Darwin.close(descriptor)
            try await session.close(handle)
            // Commit: rename over the destination atomically.
            guard Darwin.rename(partialPath, destinationPath) == 0 else {
                let code = errno
                throw SFTPError.localIOFailed(operation: "rename", code: code)
            }
            return SFTPTransferReceipt(
                bytesTransferred: receipt, resumedFromOffset: offset, attempts: 0)
        } catch {
            Darwin.close(descriptor)
            // Cleanup must survive the caller's cancellation: the server
            // is owed the CLOSE regardless, so it runs in a fresh,
            // uncancelled task.
            _ = await Task { [session] in try? await session.close(handle) }.value
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
                // The server answered EOF: the file ended where its size
                // said it would, or earlier than reported.
                endOfFile = true
                for item in pending { item.task.cancel() }
                break
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
                // A short read is end of file as far as OpenSSH's server
                // is concerned; outstanding requests past it answer EOF.
                endOfFile = true
                for item in pending { item.task.cancel() }
            }
        }
        return moved
    }

    // MARK: - Upload

    private func uploadOnce(
        sourcePath: String,
        remotePath: String,
        policy: ConflictPolicy,
        partialDisposition: PartialDisposition,
        progress: ProgressHandler?,
        session: SFTPSession
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        guard let sourceInfo = localFileInfo(sourcePath) else {
            throw SFTPError.localIOFailed(operation: "stat", code: ENOENT)
        }
        let sourceSize = sourceInfo.size
        let sourceMTime = sourceInfo.modificationSeconds

        let partialPath = Self.partialPath(for: remotePath)
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
        if resolution == .resume, let partial = partialAttributes, let partialSize = partial.size {
            // The remote partial recorded the local source's mtime in its
            // own when the interrupted upload started (see below).
            let sourceUnchanged = partial.modificationTime == sourceMTime
                && sourceSize >= partialSize
            if sourceUnchanged { offset = partialSize }
        }

        let descriptor = Darwin.open(sourcePath, O_RDONLY)
        guard descriptor >= 0 else {
            throw SFTPError.localIOFailed(operation: "open", code: errno)
        }

        var flags: SFTPOpenFlags = [.write, .create]
        if offset == 0 { flags.insert(.truncate) }
        let handle = try await session.open(path: partialPath, flags: flags)
        // Record the source's mtime on the partial now — an interruption
        // after this point leaves a resumable, self-validating partial.
        try? await session.fsetStat(
            handle: handle, attributes: SFTPAttributes(modificationTime: sourceMTime))

        let abort = AbortFlag()
        do {
            let moved = try await withTaskCancellationHandler {
                try await self.pipeUpload(
                    session: session, handle: handle, descriptor: descriptor,
                    offset: offset, total: sourceSize, progress: progress, abort: abort)
            } onCancel: {
                abort.set()
            }
            Darwin.close(descriptor)
            try await session.close(handle)
            try await commitUpload(
                session: session, partialPath: partialPath, destinationPath: remotePath,
                overwriting: destinationAttributes != nil)
            return SFTPTransferReceipt(
                bytesTransferred: moved, resumedFromOffset: offset, attempts: 0)
        } catch {
            Darwin.close(descriptor)
            _ = await Task { [session] in try? await session.close(handle) }.value
            await cleanUpPartialAsync(
                partialPath, disposition: partialDisposition,
                keepForResume: resolution == .resume, session: session)
            if let sftpError = error as? SFTPError, !abort.isSet { throw sftpError }
            throw .cancelled
        }
    }

    /// The write side of the window: `pread` a block locally, send WRITE,
    /// keep up to `pipelineDepth` unanswered.
    private func pipeUpload(
        session: SFTPSession,
        handle: SFTPHandle,
        descriptor: Int32,
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

        while !sourceDrained || !pending.isEmpty {
            if abort.isSet || Task.isCancelled {
                for item in pending { item.task.cancel() }
                throw SFTPError.cancelled
            }
            while pending.count < configuration.pipelineDepth, !sourceDrained {
                let length = min(UInt64(configuration.blockSize), total - nextOffset)
                let requestOffset = nextOffset
                let block = try readAll(descriptor: descriptor, count: Int(length), at: requestOffset)
                let task = Task<Void, any Error> {
                    try await session.write(handle: handle, offset: requestOffset, data: block)
                }
                pending.append((offset: requestOffset, length: block.count, task: task))
                nextOffset += UInt64(block.count)
                // A short or empty local read means the source shrank
                // mid-transfer; what was read up to here is uploaded.
                if block.count < Int(length) { sourceDrained = true }
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

    /// RENAME the partial over the destination. `posix-rename` is used
    /// when the server advertises it; otherwise version 3's RENAME fails
    /// against an existing destination, and the fallback — REMOVE, then
    /// RENAME — is the best the protocol offers. It is not atomic, and it
    /// is only taken when the resolution already decided to overwrite.
    private func commitUpload(
        session: SFTPSession,
        partialPath: String,
        destinationPath: String,
        overwriting: Bool
    ) async throws(SFTPError) {
        if try await session.posixRename(from: partialPath, to: destinationPath) {
            return
        }
        do {
            try await session.rename(from: partialPath, to: destinationPath)
        } catch SFTPError.server(let status) where overwriting {
            // OpenSSH's server answers SSH_FX_FAILURE here; the code is
            // not checked because draft-02 assigns no specific one.
            _ = status
            try await session.remove(path: destinationPath)
            try await session.rename(from: partialPath, to: destinationPath)
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

    /// Remote partial removal (upload path): a server round trip, so
    /// best-effort — the next resume attempt recognises the partial by
    /// name whether or not this REMOVE lands.
    private func cleanUpPartialAsync(
        _ path: String,
        disposition: PartialDisposition,
        keepForResume: Bool,
        session: SFTPSession
    ) async {
        let keep: Bool
        switch disposition {
        case .keepForResume: keep = true
        case .remove: keep = false
        case .automatic: keep = keepForResume
        }
        if !keep {
            // Uncancelled, like the CLOSE above: a cancelled transfer's
            // cleanup must still reach the server.
            _ = await Task { [session] in try? await session.remove(path: path) }.value
        }
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
            return try await task.value
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
        let token = queue.withLock { state -> UInt64 in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.withLock { state in
                    state.waiters.append((token: token, continuation: continuation))
                }
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
final class AbortFlag: @unchecked Sendable {
    private let flag = Mutex(false)

    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}
