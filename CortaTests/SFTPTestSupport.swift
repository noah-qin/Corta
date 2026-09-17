import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// B14 — the shared SFTP test support: a fake `SFTPClient` that answers in
/// the model's terms and records what it was asked, plus the small helpers
/// both the browser and the remote-edit suites build on. No ssh, no
/// network; filesystem staging stays inside per-test temp directories.
final class FakeSFTPClient: SFTPClient, @unchecked Sendable {
    struct TransferCall {
        var isUpload: Bool
        var remotePath: String
        var localPath: String
        var policy: String
        var disposition: SFTPTransferEngine.PartialDisposition
    }

    var connectError: SFTPError?
    var realPathResult = "/home/tester"
    var connectedHosts: [String] = []
    var listings: [String: [SFTPEntry]] = [:]
    var listingErrors: [String: SFTPError] = [:]
    var volumeInfoResult: SFTPVolumeInfo?
    var lstatResults: [String: SFTPAttributes] = [:]
    var madeDirectories: [String] = []
    var removed: [String] = []
    var removedDirectories: [String] = []
    var renamed: [(from: String, to: String)] = []
    var transferCalls: [TransferCall] = []
    var onTransfer: ((TransferCall, SFTPTransferEngine.ProgressHandler?) async throws -> Void)?
    var closed = false

    var capabilities: SFTPServerCapabilities?

    func connect() async throws(SFTPError) -> SFTPServerCapabilities {
        if let connectError { throw connectError }
        let capabilities = SFTPServerCapabilities(
            version: 3, extensions: [:],
            supportsStatVFS: volumeInfoResult != nil, supportsPosixRename: true)
        self.capabilities = capabilities
        return capabilities
    }

    func realPath(path: String) async throws(SFTPError) -> String { realPathResult }

    func listDirectory(path: String) async throws(SFTPError) -> [SFTPEntry] {
        if let error = listingErrors[path] { throw error }
        return listings[path] ?? []
    }

    func makeDirectory(path: String) async throws(SFTPError) { madeDirectories.append(path) }
    func remove(path: String) async throws(SFTPError) { removed.append(path) }
    func removeDirectory(path: String) async throws(SFTPError) { removedDirectories.append(path) }

    func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        renamed.append((oldPath, newPath))
    }

    func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
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
            isUpload: false, remotePath: remotePath, localPath: localDestination.path,
            policy: policy, disposition: partialDisposition, progress: progress)
    }

    func upload(
        from localSource: URL, to remotePath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        partialDisposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        try await transfer(
            isUpload: true, remotePath: remotePath, localPath: localSource.path,
            policy: policy, disposition: partialDisposition, progress: progress)
    }

    private func transfer(
        isUpload: Bool, remotePath: String, localPath: String,
        policy: SFTPTransferEngine.ConflictPolicy,
        disposition: SFTPTransferEngine.PartialDisposition,
        progress: SFTPTransferEngine.ProgressHandler?
    ) async throws(SFTPError) -> SFTPTransferEngine.SFTPTransferReceipt {
        let call = TransferCall(
            isUpload: isUpload, remotePath: remotePath, localPath: localPath,
            policy: Self.policyName(policy), disposition: disposition)
        transferCalls.append(call)
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
    var directoryCalls: [DirectoryCall] = []
    var onDirectoryTransfer:
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
        directoryCalls.append(call)
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
                .init(filesCompleted: 1, filesTotal: 2, completedBytes: 100, totalBytes: 300, currentFile: "b"))
            progress?(
                .init(filesCompleted: 2, filesTotal: 2, completedBytes: 300, totalBytes: 300, currentFile: ""))
        }
        return SFTPTransferEngine.DirectoryTransferReceipt(
            filesTransferred: 2, directoriesCreated: 1, bytesTransferred: 300, skipped: [])
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
    // Generous: a passing wait returns the moment the condition holds, and
    // on the hosted CI runner the main actor is away for about forty
    // seconds once per process — every main-actor test that happens to be
    // queued behind that stall reports ~40 s, whichever suite it is in —
    // so a deadline under a minute failed this suite about one run in
    // three while the app was fine (runs on #75, #77 and #80). Two minutes
    // costs nothing on a pass; the condition is polled every 5 ms.
    let deadline = ContinuousClock.now + .seconds(120)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
