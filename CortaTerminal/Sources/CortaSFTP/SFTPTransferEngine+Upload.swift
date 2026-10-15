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
    // MARK: - Upload

    /// What identifies an upload's source while it is read: the file the
    /// descriptor names, and the size and mtime it had when it was opened.
    struct LocalSourceIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: UInt64
        let modificationSeconds: Int
        // periphery:ignore - compared by ==, which is how a changed source is caught
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
    private struct UploadResumeRecord: Sendable {
        let source: LocalSourceIdentity
        let confirmedOffset: UInt64
    }

    private static let uploadResumeRecords = Mutex<[String: UploadResumeRecord]>([:])

    func uploadOnce(
        sourcePath: String,
        remotePath: String,
        policy: ConflictPolicy,
        partialDisposition: PartialDisposition,
        progress: ProgressHandler?,
        session: SFTPSession
    ) async throws(SFTPError) -> SFTPTransferReceipt {
        let (descriptor, source) = try Self.openUploadSource(sourcePath)
        defer { Darwin.close(descriptor) }
        let target = try await prepareUploadTarget(
            remotePath: remotePath, source: source, policy: policy, session: session)

        let abort = AbortFlag()
        let confirmedOffset = Mutex(target.offset)
        var handleOpen = true
        do {
            let moved = try await withTaskCancellationHandler {
                try await self.pipeUpload(
                    session: session, handle: target.handle, descriptor: descriptor,
                    sourcePath: sourcePath, offset: target.offset, total: source.size,
                    progress: { update in
                        confirmedOffset.withLock { $0 = update.completedBytes }
                        Self.uploadResumeRecords.withLock {
                            $0[target.recordKey] = UploadResumeRecord(
                                source: source, confirmedOffset: update.completedBytes)
                        }
                        progress?(update)
                    }, abort: abort)
            } onCancel: {
                abort.set()
            }
            try Self.verifySourceUnchanged(descriptor: descriptor, path: sourcePath, opened: source)
            handleOpen = false
            try await session.close(target.handle)
            try await commitUpload(
                session: session, partialPath: target.partialPath, destinationPath: remotePath,
                mayReplace: target.resolution != .fail)
            Self.uploadResumeRecords.withLock { $0[target.recordKey] = nil }
            return SFTPTransferReceipt(
                bytesTransferred: moved, resumedFromOffset: target.offset, attempts: 0)
        } catch {
            let failure = error as? SFTPError
            if let failure, failure.isIncompleteReplacement {
                // The partial may be the only copy of the new content now;
                // the error names where both copies are.
                Self.uploadResumeRecords.withLock { $0[target.recordKey] = nil }
                throw failure
            }
            await cleanUpFailedUpload(
                handle: handleOpen ? target.handle : nil, partialPath: target.partialPath,
                keep: Self.keepsPartial(partialDisposition, keepForResume: target.resolution == .resume),
                confirmedOffset: { confirmedOffset.withLock { $0 } }, source: source,
                recordKey: target.recordKey, session: session)
            if let failure, !abort.isSet { throw failure }
            throw .cancelled
        }
    }

    /// Where an upload writes, once its conflict is resolved: the partial,
    /// its resume-record key, the resolution, the offset to resume from and
    /// the open handle.
    private struct UploadTarget {
        let partialPath: String
        let recordKey: String
        let resolution: ConflictResolution
        let offset: UInt64
        let handle: SFTPHandle
    }

    /// Resolves the conflict at `remotePath`, opens the partial and stamps
    /// it with the source's mtime, recording it for a later resume.
    private func prepareUploadTarget(
        remotePath: String,
        source: LocalSourceIdentity,
        policy: ConflictPolicy,
        session: SFTPSession
    ) async throws(SFTPError) -> UploadTarget {
        let partialPath = Self.partialPath(for: remotePath)
        let recordKey = remoteClaim(partialPath)
        let destinationAttributes = try? await session.lstat(path: remotePath)
        let partialAttributes = try? await session.lstat(path: partialPath)

        let resolution = try resolve(
            policy: policy,
            conflict: SFTPConflict(
                destinationExists: destinationAttributes != nil,
                partialSize: partialAttributes?.size,
                sourceSize: source.size),
            destinationPath: remotePath)

        let offset =
            resolution == .resume
            ? Self.uploadResumeOffset(partial: partialAttributes, source: source, recordKey: recordKey)
            : 0
        let handle = try await openUploadPartial(
            partialPath, fresh: offset == 0, replacing: partialAttributes != nil, session: session)
        Self.uploadResumeRecords.withLock {
            $0[recordKey] = UploadResumeRecord(source: source, confirmedOffset: offset)
        }
        try? await session.fsetStat(
            handle: handle, attributes: SFTPAttributes(modificationTime: source.sftpModificationTime))
        return UploadTarget(
            partialPath: partialPath, recordKey: recordKey, resolution: resolution,
            offset: offset, handle: handle)
    }

    /// The upload's source, opened. The descriptor, not the name, is what is
    /// uploaded: its size and mtime at open are the ones the transfer is
    /// checked against.
    private static func openUploadSource(
        _ path: String
    ) throws(SFTPError) -> (descriptor: Int32, identity: LocalSourceIdentity) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw .localIOFailed(operation: code == ENOENT ? "stat" : "open", code: code)
        }
        var openedStat = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedStat) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw .localIOFailed(operation: "fstat", code: code)
        }
        return (descriptor, LocalSourceIdentity(openedStat))
    }

    /// Where an upload the user chose to resume picks up: the remote partial
    /// recorded the local source's mtime in its own when the interrupted
    /// upload was cleaned up (`cleanUpFailedUpload`), or this process
    /// remembers writing it from this very source. Anything else restarts.
    private static func uploadResumeOffset(
        partial: SFTPAttributes?, source: LocalSourceIdentity, recordKey: String
    ) -> UInt64 {
        guard let partial, let partialSize = partial.size, source.size >= partialSize else { return 0 }
        let recorded = uploadResumeRecords.withLock { $0[recordKey] }
        if let recorded, recorded.source == source { return min(partialSize, recorded.confirmedOffset) }
        return partial.modificationTime == source.sftpModificationTime ? partialSize : 0
    }

    /// Opens the remote partial for writing. From zero, the partial is this
    /// transfer's own file: the old name goes, and the new one is created
    /// exclusively. A handle another process still holds then writes into a
    /// file nobody commits — never into this one after it is renamed into place.
    private func openUploadPartial(
        _ partialPath: String, fresh: Bool, replacing: Bool, session: SFTPSession
    ) async throws(SFTPError) -> SFTPHandle {
        var flags: SFTPOpenFlags = [.write]
        if fresh {
            if replacing { try await session.remove(path: partialPath) }
            flags.formUnion([.create, .exclude])
        }
        do throws(SFTPError) {
            return try await session.open(path: partialPath, flags: flags)
        } catch {
            // OpenSSH answers an exclusive create of an existing name with
            // a plain FAILURE: someone else made the partial since the check.
            if fresh, error.isPlainServerFailure { throw .destinationConflict(path: partialPath) }
            throw error
        }
    }

    /// After a failed upload: close `handle` if still open, then either keep
    /// the partial at a safe resume point or remove it.
    private func cleanUpFailedUpload(
        handle: SFTPHandle?, partialPath: String, keep: Bool, confirmedOffset: () -> UInt64,
        source: LocalSourceIdentity, recordKey: String, session: SFTPSession
    ) async {
        let handleClosed = Mutex(handle == nil)
        if let handle {
            await cleanUpRemote {
                do {
                    try await session.close(handle)
                    handleClosed.withLock { $0 = true }
                } catch {}
            }
        }
        guard keep else {
            Self.uploadResumeRecords.withLock { $0[recordKey] = nil }
            await cleanUpRemote { try? await session.remove(path: partialPath) }
            return
        }
        // Concurrent WRITE tasks can reach the server out of offset order.
        // File size may include holes beyond the acknowledged contiguous
        // prefix. CLOSE is a barrier against late writes; only then truncate
        // and stamp a safe resume point.
        guard handleClosed.withLock({ $0 }) else { return }
        let prefix = confirmedOffset()
        let modificationTime = source.sftpModificationTime
        await cleanUpRemote {
            do {
                try await session.setStat(
                    path: partialPath,
                    attributes: SFTPAttributes(size: prefix, modificationTime: modificationTime))
                Self.uploadResumeRecords.withLock {
                    $0[recordKey] = UploadResumeRecord(source: source, confirmedOffset: prefix)
                }
            } catch {}
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
}
