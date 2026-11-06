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
import Testing

/// The shared SFTP test support: a fake `SFTPClient` that answers in
/// the model's terms and records what it was asked, plus the small helpers
/// both the browser and the remote-edit suites build on. No ssh, no
/// network; filesystem staging stays inside per-test temp directories.
/// One value behind a lock. The fake's methods run on the cooperative
/// pool while the tests read and stub it from the main actor; TSAN caught
/// `rename` writing `renamed` while a `waitUntil` condition read it. Each
/// access is atomic, and the fake's own read-modify-writes go through
/// `mutate`, so a concurrent append is never lost either.
@propertyWrapper
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) { value = wrappedValue }

    var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    var projectedValue: Guarded<Value> { self }

    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

final class FakeSFTPClient: SFTPClient, @unchecked Sendable {
    struct TransferCall {
        var isUpload: Bool
        var remotePath: String
        var localPath: String
        var policy: String
        var disposition: SFTPTransferEngine.PartialDisposition
    }

    @Guarded var connectError: SFTPError?
    @Guarded var realPathResult = "/home/tester"
    @Guarded var connectedHosts: [String] = []
    @Guarded var listings: [String: [SFTPEntry]] = [:]
    @Guarded var listingErrors: [String: SFTPError] = [:]
    @Guarded var volumeInfoResult: SFTPVolumeInfo?
    @Guarded var lstatResults: [String: SFTPAttributes] = [:]
    @Guarded var lstatErrors: [String: SFTPError] = [:]
    @Guarded var madeDirectories: [String] = []
    @Guarded var removed: [String] = []
    @Guarded var removedDirectories: [String] = []
    @Guarded var renamed: [(from: String, to: String)] = []
    @Guarded var transferCalls: [TransferCall] = []
    @Guarded var onTransfer: ((TransferCall, SFTPTransferEngine.ProgressHandler?) async throws -> Void)?
    @Guarded var closed = false
    @Guarded var lstatHangs = false
    /// `lstat`s suspended by `lstatHangs`, and whether one has been cancelled.
    @Guarded var lstatsWaiting = 0
    @Guarded var lstatCancelled = false
    /// Listings suspended until cancelled or closed, by path.
    @Guarded var hangingListings: Set<String> = []
    @Guarded var cancelledListings: [String] = []

    @Guarded var capabilities: SFTPServerCapabilities?

    /// A server that never answers INIT: `connect` waits until `close`.
    @Guarded var connectHangs = false

    func connect() async throws(SFTPError) -> SFTPServerCapabilities {
        if connectHangs {
            while !closed {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
            throw .transport(.closed)
        }
        if let connectError { throw connectError }
        let capabilities = SFTPServerCapabilities(
            version: 3, extensions: [:],
            supportsStatVFS: volumeInfoResult != nil, supportsPosixRename: true)
        self.capabilities = capabilities
        return capabilities
    }

    func realPath(path: String) async throws(SFTPError) -> String { realPathResult }

    func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        if hangingListings.contains(path) {
            while !closed, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard Task.isCancelled else { throw .transport(.closed) }
            $cancelledListings.mutate { $0.append(path) }
            throw .cancelled
        }
        if let error = listingErrors[path] { throw error }
        return listings[path] ?? []
    }

    func makeDirectory(path: String) async throws(SFTPError) { $madeDirectories.mutate { $0.append(path) } }
    func remove(path: String) async throws(SFTPError) { $removed.mutate { $0.append(path) } }
    func removeDirectory(path: String) async throws(SFTPError) { $removedDirectories.mutate { $0.append(path) } }

    func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        $renamed.mutate { $0.append((oldPath, newPath)) }
    }

    func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        if lstatHangs {
            $lstatsWaiting.mutate { $0 += 1 }
            defer { $lstatsWaiting.mutate { $0 -= 1 } }
            while !closed {
                do {
                    try await Task.sleep(for: .milliseconds(5))
                } catch {
                    lstatCancelled = true
                    throw .cancelled
                }
            }
            throw .transport(.closed)
        }
        if let error = lstatErrors[path] { throw error }
        if let attributes = lstatResults[path] { return attributes }
        throw .server(SFTPStatus(code: .noSuchFile))
    }

    func volumeInfo(path: String) async throws(SFTPError) -> SFTPVolumeInfo? {
        volumeInfoResult
    }

    func download(
        remotePath: String, to localDestination: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        try await transfer(
            TransferCall(
                isUpload: false, remotePath: remotePath, localPath: localDestination.path,
                policy: Self.policyName(policy), disposition: partialDisposition),
            progress: progress)
    }

    func upload(
        from localSource: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        try await transfer(
            TransferCall(
                isUpload: true, remotePath: remotePath, localPath: localSource.path,
                policy: Self.policyName(policy), disposition: partialDisposition),
            progress: progress)
    }

    private func transfer(
        _ call: TransferCall, progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        $transferCalls.mutate { $0.append(call) }
        if let onTransfer {
            do {
                try await onTransfer(call, progress)
            } catch let error as SFTPError {
                throw error
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .protocolViolation("\(error)")
            }
        } else {
            progress?(.init(completedBytes: 50, totalBytes: 100))
            progress?(.init(completedBytes: 100, totalBytes: 100))
        }
        return SFTPTransferEngine.SFTPTransferReceipt(
            bytesTransferred: 100, resumedFromOffset: 0, attempts: 1)
    }

    /// Directory transfers, recorded like the file ones; `onDirectoryTransfer`
    /// can fail or stall them, otherwise a two-file receipt comes back.
    struct DirectoryCall: Equatable {
        var isUpload: Bool
        var remotePath: String
        var localPath: String
        var policy: String
    }
    @Guarded var directoryCalls: [DirectoryCall] = []
    /// Names a directory transfer's receipt says it skipped.
    @Guarded var directorySkipped: [String] = []
    @Guarded var onDirectoryTransfer:
        ((DirectoryCall, SFTPTransferEngine.DirectoryProgressHandler?) async throws -> Void)?

    func downloadDirectory(
        remotePath: String, to localDirectory: URL,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        try await directoryTransfer(
            isUpload: false, remotePath: remotePath, localPath: localDirectory.path,
            policy: policy, progress: progress)
    }

    func uploadDirectory(
        from localDirectory: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        try await directoryTransfer(
            isUpload: true, remotePath: remotePath, localPath: localDirectory.path,
            policy: policy, progress: progress)
    }

    private func directoryTransfer(
        isUpload: Bool, remotePath: String, localPath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        progress: SFTPTransferEngine.DirectoryProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.DirectoryTransferReceipt {
        let call = DirectoryCall(
            isUpload: isUpload, remotePath: remotePath, localPath: localPath,
            policy: Self.policyName(policy))
        $directoryCalls.mutate { $0.append(call) }
        if let onDirectoryTransfer {
            do {
                try await onDirectoryTransfer(call, progress)
            } catch let error as SFTPError {
                throw error
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .protocolViolation("\(error)")
            }
        } else {
            progress?(
                .init(filesCompleted: 1, filesTotal: 2, completedBytes: 100, totalBytes: 300))
            progress?(
                .init(filesCompleted: 2, filesTotal: 2, completedBytes: 300, totalBytes: 300))
        }
        return SFTPTransferEngine.DirectoryTransferReceipt(
            filesTransferred: 2, directoriesCreated: 1, bytesTransferred: 300,
            skipped: directorySkipped.map { .init(relativePath: $0, reason: .symbolicLink) })
    }

    private static func policyName(_ policy: SFTPTransferEngine.ConflictPolicy) -> String {
        switch policy {
        case .fail: return "fail"
        case .overwrite: return "overwrite"
        case .resume: return "resume"
        case .decide: return "decide"
        }
    }

    func close() { closed = true }
}

func makeEntry(
    _ name: String, permissions: UInt32? = 0o100644, size: UInt64? = 128
) -> SFTPEntry {
    SFTPEntry(
        filename: Array(name.utf8),
        attributes: SFTPAttributes(size: size, permissions: permissions))
}

@MainActor
func waitUntil(
    _ description: String,
    condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    // A passing wait returns the moment the condition holds; the ceiling
    // only decides how long a failing one takes to say so, and scales on CI
    // like every other wait in this target (`testTimeoutScale`). It counts
    // what this loop saw, a tick at a time: another test blocking the main
    // actor for seconds is not this condition failing to come true, and the
    // work it waits for may be queued right behind this check.
    let ceiling = .seconds(15) * testTimeoutScale
    let clock = SuspendingClock()
    var waited = Duration.zero
    var last = clock.now
    while !condition() {
        if waited > ceiling {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
        let now = clock.now
        waited += min(last.duration(to: now), .milliseconds(50))
        last = now
    }
}

@MainActor
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
