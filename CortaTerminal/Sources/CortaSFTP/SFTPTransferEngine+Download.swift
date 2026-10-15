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
import Foundation
import Synchronization

extension SFTPTransferEngine {
    // MARK: - Download

    func downloadOnce(
        remotePath: String,
        destinationPath: String,
        policy: ConflictPolicy,
        partialDisposition: PartialDisposition,
        progress: ProgressHandler?,
        session: SFTPSession,
        ownedPartial: borrowing Mutex<LocalPartialIdentity?>
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        let sourceAttributes = try await session.stat(path: remotePath)
        try checkDownloadLimit(sourceAttributes)
        let partialPath = Self.partialPath(for: destinationPath)
        let partialInfo = localFileInfo(partialPath)
        let conflict = downloadConflict(
            destinationPath: destinationPath, partialPath: partialPath, partial: partialInfo,
            source: sourceAttributes, ownedPartial: ownedPartial.withLock { $0 })
        let resolution = try resolve(policy: policy, conflict: conflict, destinationPath: destinationPath)
        let offset =
            resolution == .resume
            ? Self.downloadResumeOffset(partial: partialInfo, source: sourceAttributes) : 0

        let (handle, descriptor) = try await openDownloadEnds(
            remotePath: remotePath, partialPath: partialPath, fresh: offset == 0,
            replacing: partialInfo != nil, session: session, ownedPartial: ownedPartial)

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
            try await verifyRemoteSourceUnchanged(remotePath, opened: sourceAttributes, session: session)
            try commitDownload(partialPath, to: destinationPath, mayReplace: resolution != .fail)
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

    /// Refuses a download larger than the configured ceiling before
    /// anything is opened.
    private func checkDownloadLimit(_ source: SFTPAttributes) throws(SFTPError) {
        if let limit = configuration.maximumDownloadBytes, let size = source.size, size > limit {
            throw .localIOFailed(operation: "download size limit", code: EFBIG)
        }
    }

    /// Opens the remote source, then the local partial. Remote first: a
    /// refused OPEN must leave no local partial behind, and nothing open to
    /// leak.
    private func openDownloadEnds(
        remotePath: String,
        partialPath: String,
        fresh: Bool,
        replacing: Bool,
        session: SFTPSession,
        ownedPartial: borrowing Mutex<LocalPartialIdentity?>
    ) async throws(SFTPError) -> (handle: SFTPHandle, descriptor: Int32) {
        let handle = try await session.open(path: remotePath, flags: .read)
        // A transfer from zero gets a file of its own: the old partial's
        // name is removed and a new one created exclusively, so whoever
        // still holds the old one open writes into a file nothing commits,
        // never into this transfer's.
        if fresh, replacing { Darwin.unlink(partialPath) }
        do throws(SFTPError) {
            let opened = try Self.openPrivatePartial(partialPath, fresh: fresh)
            ownedPartial.withLock { $0 = opened.identity }
            return (handle, opened.descriptor)
        } catch {
            await cleanUpRemote { try? await session.close(handle) }
            throw error
        }
    }

    /// A source that changed while it was read is not the file that was
    /// asked for: what landed may mix two versions, or stop short.
    private func verifyRemoteSourceUnchanged(
        _ remotePath: String, opened: SFTPAttributes, session: SFTPSession
    ) async throws(SFTPError) {
        let after = try await session.stat(path: remotePath)
        if after.size != opened.size || after.modificationTime != opened.modificationTime {
            throw .sourceChanged(path: remotePath)
        }
    }

    /// What already stands where a download would land: the destination,
    /// a partial, and whether that partial is the one this download made.
    private func downloadConflict(
        destinationPath: String, partialPath: String, partial: LocalFileInfo?,
        source: SFTPAttributes, ownedPartial: LocalPartialIdentity?
    ) -> SFTPConflict {
        var conflict = SFTPConflict(
            destinationExists: FileManager.default.fileExists(atPath: destinationPath),
            partialSize: partial?.size,
            sourceSize: source.size)
        var partialStat = Darwin.stat()
        if let ownedPartial, Darwin.lstat(partialPath, &partialStat) == 0 {
            conflict.partialIsOwned = ownedPartial == LocalPartialIdentity(
                device: partialStat.st_dev, inode: partialStat.st_ino)
        }
        return conflict
    }

    /// Where a download the user chose to resume picks up. The partial is
    /// trustworthy only if the source still has the size and mtime the
    /// partial recorded in its own mtime when the interrupted transfer
    /// started. Otherwise it is a fragment of a different file and the
    /// transfer restarts at zero.
    private static func downloadResumeOffset(partial: LocalFileInfo?, source: SFTPAttributes) -> UInt64 {
        guard let partial else { return 0 }
        let sourceUnchanged = source.modificationTime == partial.modificationSeconds
            && (source.size.map { $0 >= partial.size } ?? true)
        return sourceUnchanged ? partial.size : 0
    }

    /// A download's partial, opened for writing and made private: created
    /// exclusively when `fresh`, so a stale holder of the old name writes
    /// into a file nothing commits. Its identity is how a retry recognises it.
    private static func openPrivatePartial(
        _ path: String, fresh: Bool
    ) throws(SFTPError) -> (descriptor: Int32, identity: LocalPartialIdentity) {
        let descriptor = Darwin.open(
            path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (fresh ? O_EXCL : 0), 0o600)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { throw .destinationConflict(path: path) }
            throw .localIOFailed(operation: "open", code: code)
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
            throw .localIOFailed(operation: "private download permissions", code: code)
        }
        var openedStat = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedStat) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw .localIOFailed(operation: "fstat partial", code: code)
        }
        return (descriptor, LocalPartialIdentity(device: openedStat.st_dev, inode: openedStat.st_ino))
    }

    /// Renames a finished partial over the destination atomically — or, when
    /// the policy forbids replacing it, only if it is still absent: a file
    /// that appeared since the check is not ours to overwrite.
    private func commitDownload(
        _ partialPath: String, to destinationPath: String, mayReplace: Bool
    ) throws(SFTPError) {
        // On the partial, so the file appears at its name already marked:
        // marked after the rename, it sat there unmarked for a moment.
        if configuration.quarantinesDownloads { Self.markQuarantined(partialPath) }
        let renamed =
            mayReplace
            ? Darwin.rename(partialPath, destinationPath)
            : renamex_np(partialPath, destinationPath, UInt32(RENAME_EXCL))
        guard renamed == 0 else {
            let code = errno
            if code == EEXIST { throw .destinationConflict(path: destinationPath) }
            throw .localIOFailed(operation: "rename", code: code)
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
        var pending: [PendingRead] = []
        pending.reserveCapacity(configuration.pipelineDepth)
        defer { for item in pending { item.task.cancel() } }

        while !endOfFile {
            if abort.isSet || Task.isCancelled {
                for item in pending { item.task.cancel() }
                throw SFTPError.cancelled
            }
            fillReadWindow(&pending, from: &nextOffset, total: total, session: session, handle: handle)
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
            try writeBlock(data, for: first, to: descriptor, sourceModificationSeconds: sourceModificationSeconds)
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

    private typealias PendingRead = (offset: UInt64, length: Int, task: Task<[UInt8], any Error>)

    /// Asks for blocks from `nextOffset` until `pipelineDepth` READs are in
    /// flight or the known size is reached.
    private func fillReadWindow(
        _ pending: inout [PendingRead], from nextOffset: inout UInt64, total: UInt64?,
        session: SFTPSession, handle: SFTPHandle
    ) {
        while pending.count < configuration.pipelineDepth {
            if let total, nextOffset >= total { return }
            let remaining = total.map { $0 - nextOffset }
            let length = UInt32(min(UInt64(configuration.blockSize), remaining ?? UInt64.max))
            if length == 0 { return }
            let requestOffset = nextOffset
            let task = Task<[UInt8], any Error> {
                try await session.read(handle: handle, offset: requestOffset, length: length)
            }
            pending.append((offset: requestOffset, length: Int(length), task: task))
            nextOffset += UInt64(length)
        }
    }

    /// Writes one READ's reply at its offset, after checking it is a reply
    /// to that READ and within the size limit.
    private func writeBlock(
        _ data: [UInt8], for read: PendingRead, to descriptor: Int32, sourceModificationSeconds: UInt32?
    ) throws(SFTPError) {
        // More than was asked is no reply to the READ: written, it ran
        // past the stated size and under the next block.
        guard data.count <= read.length else {
            throw .protocolViolation("READ reply longer than requested")
        }
        if let limit = configuration.maximumDownloadBytes, read.offset + UInt64(data.count) > limit {
            throw .localIOFailed(operation: "download size limit", code: EFBIG)
        }
        try writeAll(descriptor: descriptor, bytes: data, at: read.offset)
        // The partial's mtime is the resume-validation record, but every
        // pwrite bumps it — restamp after each block so an interruption at
        // any point leaves a self-validating partial.
        if let seconds = sourceModificationSeconds {
            stampModificationTime(descriptor, seconds: seconds)
        }
    }
}
