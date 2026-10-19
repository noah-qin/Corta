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

extension SFTPTransferEngine {
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

    // MARK: - Policy

    func resolve(
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
    func cleanUpPartial(
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
    func cleanUpRemote(_ operation: @escaping @Sendable () async -> Void) async {
        let cleanup = Task { await operation() }
        let timeout = configuration.cleanupTimeout
        let timer = Task {
            do { try await Task.sleep(for: timeout, clock: .suspending) } catch { return }
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
    typealias LocalFileInfo = (size: UInt64, modificationSeconds: UInt32)

    func localFileInfo(_ path: String) -> LocalFileInfo? {
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
    func taskValue<Success>(
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
    func stampModificationTime(_ descriptor: Int32, seconds: UInt32) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: 0),
        ]
        _ = futimens(descriptor, &times)
    }

    func writeAll(descriptor: Int32, bytes: [UInt8], at offset: UInt64) throws(SFTPError) {
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

    func readAll(descriptor: Int32, count: Int, at offset: UInt64) throws(SFTPError) -> [UInt8] {
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
}
