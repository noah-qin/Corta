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

import Foundation
import Synchronization
import Testing

@testable import CortaSFTP

/// The transfer engine against the scripted fake server: atomic
/// destinations, resume with endpoint validation, conflict policies,
/// cancellation, the concurrency queue, and retry with reconnect. Local
/// files live in a per-test temporary directory; nothing else on the
/// machine is touched.
@Suite("SFTP transfers", .serialized)
struct SFTPTransferTests {
    /// One test's world: temp directory, loopback, fake filesystem+server,
    /// connected session and engine.
    struct Rig {
        let directory: URL
        let connection: SFTPLoopbackConnection
        let fileSystem: FakeRemoteFileSystem
        let server: FakeSFTPServer
        let session: SFTPSession
        let engine: SFTPTransferEngine

        var partialName: String { SFTPTransferEngine.partialSuffix }
    }

    func makeRig(
        configureEngine: (inout SFTPTransferEngine.Configuration) -> Void = { _ in },
        reconnect: SFTPTransferEngine.ReconnectHandler? = nil,
        configureServer: (FakeSFTPServer) -> Void = { _ in }
    ) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        configureServer(server)
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()

        var configuration = SFTPTransferEngine.Configuration()
        // Small blocks so multi-block behaviour shows up in small files.
        configuration.blockSize = 512
        configuration.pipelineDepth = 4
        configuration.initialBackoff = .milliseconds(10)
        configuration.maximumBackoff = .milliseconds(20)
        configureEngine(&configuration)
        let engine = SFTPTransferEngine(
            session: session, reconnect: reconnect, configuration: configuration)
        return Rig(
            directory: directory, connection: connection, fileSystem: fileSystem,
            server: server, session: session, engine: engine)
    }

    func teardown(_ rig: Rig) {
        rig.session.close()
        rig.connection.close()
        try? FileManager.default.removeItem(at: rig.directory)
    }

    func localFile(_ rig: Rig, _ name: String, contents: [UInt8], mtime: UInt32? = nil) throws -> URL {
        let url = rig.directory.appendingPathComponent(name)
        try contents.withUnsafeBytes { buffer in
            try Data(buffer).write(to: url)
        }
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
                ofItemAtPath: url.path)
        }
        return url
    }

    func localContents(_ url: URL) -> [UInt8]? {
        try? Array(Data(contentsOf: url))
    }

    // MARK: - Download

    @Test("remote file sizes can overflow the aggregate without crashing")
    func oversizedDirectoryTotals() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/dir/a", data: [])
        let answered = Mutex(false)
        rig.server.interceptor = { message in
            if case .readdir = message.payload {
                let first = answered.withLock { seen in
                    defer { seen = true }
                    return !seen
                }
                if !first { return .reply(.name([])) }
                return .reply(.name([
                    SFTPEntry(filename: [97], attributes: .init(size: .max)),
                    SFTPEntry(filename: [98], attributes: .init(size: 1)),
                ]))
            }
            return .proceed
        }
        // A direct plan exercises the same metadata aggregate without
        // attempting a physically impossible transfer.
        var plan = SFTPTransferEngine.TreePlan()
        plan.addFile("a", size: .max)
        plan.addFile("b", size: 1)
        #expect(plan.totalBytes == nil)
        plan.addFile("c", size: 0)
        #expect(plan.totalBytes == nil)
        var ordinary = SFTPTransferEngine.TreePlan()
        ordinary.addFile("a", size: 2)
        ordinary.addFile("b", size: 3)
        #expect(ordinary.totalBytes == 5)
        let remotePlan = try await rig.engine.enumerateRemote(root: "/dir")
        #expect(remotePlan.files.count == 2)
        #expect(remotePlan.totalBytes == nil)
    }

    @Test("nonempty directory batches stop at the aggregate entry cap")
    func endlessDirectoryListingIsBounded() async throws {
        let rig = try await makeRig(configureEngine: { $0.maximumDirectoryEntries = 3 })
        defer { teardown(rig) }
        rig.fileSystem.createFile("/dir/a", data: [])
        rig.server.interceptor = { message in
            if case .readdir = message.payload {
                return .reply(.name([SFTPEntry(filename: [97])]))
            }
            return .proceed
        }
        await #expect(throws: SFTPError.protocolViolation("directory entry limit exceeded")) {
            try await rig.engine.listDirectory(path: "/dir")
        }
        #expect(rig.server.log.operations.filter { $0 == "readdir" }.count == 4)
        #expect(rig.server.log.closeCount == 1)
    }

    @Test("longnames and extended attributes consume the listing byte budget")
    func listingMetadataIsBudgeted() async throws {
        for extended in [false, true] {
            let rig = try await makeRig(configureEngine: { $0.maximumDirectoryBytes = 256 })
            defer { teardown(rig) }
            rig.fileSystem.createFile("/dir/a", data: [])
            let entry = SFTPEntry(
                filename: [97], longname: extended ? [] : [UInt8](repeating: 98, count: 256),
                attributes: .init(extended: extended
                    ? [.init(name: [], data: [UInt8](repeating: 99, count: 256))] : []))
            rig.server.interceptor = { message in
                if case .readdir = message.payload { return .reply(.name([entry])) }
                return .proceed
            }
            await #expect(throws: SFTPError.protocolViolation("directory byte limit exceeded")) {
                try await rig.engine.listDirectory(path: "/dir")
            }
            #expect(rig.server.log.closeCount == 1)
        }
    }

    @Test("tree entry, depth and path budgets fail before destination writes")
    func remoteTreeIsBounded() async throws {
        for limit in 0..<3 {
            let rig = try await makeRig(configureEngine: {
                if limit == 0 { $0.maximumTreeEntries = 1 }
                if limit == 1 { $0.maximumTreeDepth = 1 }
                if limit == 2 { $0.maximumTreePathBytes = 1 }
            })
            defer { teardown(rig) }
            rig.fileSystem.createFile("/tree/a/b/file", data: [1])
            let target = rig.directory.appendingPathComponent("destination")
            await #expect(throws: SFTPError.self) {
                try await rig.engine.downloadDirectory(remotePath: "/tree", to: target)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test("cancel aborts silent READ/WRITE and CLOSE without retaining a transfer slot")
    func cancellationWithSilentPeer() async throws {
        for uploading in [false, true] {
            let rig = try await makeRig(configureEngine: {
                $0.maxConcurrentTransfers = 1
                $0.cleanupTimeout = .milliseconds(20)
            })
            defer { teardown(rig) }
            rig.fileSystem.createFile("/file", data: [UInt8](repeating: 1, count: 4096))
            let source = try localFile(rig, "source", contents: [UInt8](repeating: 2, count: 4096))
            let destination = rig.directory.appendingPathComponent("download")
            let observedRequest = Mutex(false)
            rig.server.interceptor = { message in
                switch message.payload {
                case .read, .write:
                    observedRequest.withLock { $0 = true }
                    return .ignore
                case .close, .remove: return .ignore
                default: return .proceed
                }
            }
            let completed = Mutex(false)
            let transfer = Task {
                defer { completed.withLock { $0 = true } }
                if uploading {
                    return try await rig.engine.upload(from: source, to: "/upload", policy: .overwrite)
                }
                return try await rig.engine.download(remotePath: "/file", to: destination, policy: .overwrite)
            }
            let deadline = SuspendingClock.now + .seconds(testTimeoutInterval(3))
            #expect(try await waitForFlag(observedRequest, until: deadline))
            transfer.cancel()
            #expect(
                try await waitForFlag(completed, until: deadline), "cancellation must not need a remote response")
            if !completed.withLock({ $0 }) { rig.session.close() }
            do {
                _ = try await transfer.value
                Issue.record("cancelled transfer unexpectedly succeeded")
            } catch {
                #expect(error as? SFTPError == .cancelled)
            }
            #expect(
                descriptorsNaming(uploading ? source.path : SFTPTransferEngine.partialPath(for: destination.path))
                    .isEmpty)
            if completed.withLock({ $0 }) {
                rig.server.interceptor = nil
                try await rig.engine.download(
                    remotePath: "/file", to: rig.directory.appendingPathComponent("next"), policy: .overwrite)
            }
        }
    }
}

extension SFTPTransferTests {
    @Test("at most the configured number of transfers run at once, FIFO")
    func queueBound() async throws {
        let rig = try await makeRig(
            configureEngine: { $0.maxConcurrentTransfers = 2 },
            configureServer: { $0.replyDelay = .milliseconds(30) })
        defer { teardown(rig) }
        for index in 0..<4 {
            rig.fileSystem.createFile(
                "/f\(index)", data: [UInt8](repeating: UInt8(index), count: 8192))
        }

        // The server-side evidence: concurrent open read handles can never
        // exceed the queue's bound.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                let destination = rig.directory.appendingPathComponent("out\(index)")
                group.addTask {
                    try await rig.engine.download(
                        remotePath: "/f\(index)", to: destination, policy: .overwrite)
                }
            }
            try await group.waitForAll()
        }
        for index in 0..<4 {
            #expect(localContents(rig.directory.appendingPathComponent("out\(index)"))?.count == 8192)
        }
        // With a 30 ms reply delay and four queued transfers, a broken
        // queue would show three or four handles open at once.
        #expect(rig.server.log.maxOutstandingReads <= 2 * 4)  // 2 transfers × pipeline depth
    }

    @Test("a refused remote open leaves no local partial and no descriptor behind")
    func refusedOpenLeaksNothing() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/refused", data: [1, 2, 3])
        rig.server.refusedPaths = ["/refused", "/up.bin" + rig.partialName]

        let destination = rig.directory.appendingPathComponent("down.bin")
        let partial = rig.directory.appendingPathComponent("down.bin" + rig.partialName)
        await #expect(throws: SFTPError.self) {
            try await rig.engine.download(
                remotePath: "/refused", to: destination, policy: .overwrite)
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(descriptorsNaming(partial.path).isEmpty)

        let source = try localFile(rig, "up.bin", contents: [4, 5, 6])
        await #expect(throws: SFTPError.self) {
            try await rig.engine.upload(from: source, to: "/up.bin", policy: .overwrite)
        }
        #expect(
            descriptorsNaming(source.path).isEmpty,
            "the upload's local source stayed open after the remote open failed")
    }

    /// This process's descriptors whose file is at `path`.
    private func descriptorsNaming(_ path: String) -> [Int32] {
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var found: [Int32] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in Int32(0)..<Int32(getdtablesize()) where fcntl(fd, F_GETPATH, &buffer) == 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self)
            if URL(fileURLWithPath: name).resolvingSymlinksInPath().path == wanted {
                found.append(fd)
            }
        }
        return found
    }

    // MARK: - Transport retry

    @Test("a server status is definitive: never retried")
    func serverErrorsAreNotRetried() async throws {
        let reconnectCalls = Mutex(0)
        let rig = try await makeRig(
            reconnect: {
                reconnectCalls.withLock { $0 += 1 }
                throw SFTPError.cancelled
            })
        defer { teardown(rig) }
        rig.fileSystem.createFile("/refused", data: [])
        rig.server.refusedPaths = ["/refused"]

        let destination = rig.directory.appendingPathComponent("out")
        do {
            _ = try await rig.engine.download(
                remotePath: "/refused", to: destination, policy: .overwrite)
            Issue.record("a permission-denied open should fail the transfer")
        } catch {
            guard case SFTPError.server(let status) = error else {
                Issue.record("expected a server status, got \(error)")
                return
            }
            #expect(status.code == .permissionDenied)
        }
        #expect(reconnectCalls.withLock { $0 } == 0)
    }
}
