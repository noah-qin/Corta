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
    private struct Rig {
        let directory: URL
        let connection: SFTPLoopbackConnection
        let fileSystem: FakeRemoteFileSystem
        let server: FakeSFTPServer
        let session: SFTPSession
        let engine: SFTPTransferEngine

        var partialName: String { SFTPTransferEngine.partialSuffix }
    }

    private func makeRig(
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

    private func teardown(_ rig: Rig) {
        rig.session.close()
        rig.connection.close()
        try? FileManager.default.removeItem(at: rig.directory)
    }

    private func localFile(_ rig: Rig, _ name: String, contents: [UInt8], mtime: UInt32? = nil) throws -> URL {
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

    private func localContents(_ url: URL) -> [UInt8]? {
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
            let deadline = ContinuousClock.now + .seconds(3)
            while !observedRequest.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(observedRequest.withLock { $0 })
            transfer.cancel()
            while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(completed.withLock { $0 }, "cancellation must not need a remote response")
            if !completed.withLock({ $0 }) { rig.session.close() }
            do {
                _ = try await transfer.value
                Issue.record("cancelled transfer unexpectedly succeeded")
            } catch {
                #expect(error as? SFTPError == .cancelled)
            }
            #expect(descriptorsNaming(uploading ? source.path : SFTPTransferEngine.partialPath(for: destination.path)).isEmpty)
            if completed.withLock({ $0 }) {
                rig.server.interceptor = nil
                try await rig.engine.download(
                    remotePath: "/file", to: rig.directory.appendingPathComponent("next"), policy: .overwrite)
            }
        }
    }

    @Test("a download lands atomically: the destination never holds partial bytes")
    func downloadIsAtomic() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        let contents = (0..<4096).map { UInt8($0 % 251) }
        rig.fileSystem.createFile("/remote.bin", data: contents)

        let destination = rig.directory.appendingPathComponent("out.bin")
        let partial = rig.directory.appendingPathComponent("out.bin" + rig.partialName)
        // Every progress callback observes the world mid-transfer: the
        // destination must not exist yet, and everything in flight lives
        // under the partial name.
        let violationCount = Mutex(0)
        let receipt = try await rig.engine.download(
            remotePath: "/remote.bin", to: destination, policy: .overwrite
        ) { progress in
            if FileManager.default.fileExists(atPath: destination.path) {
                violationCount.withLock { $0 += 1 }
            }
            #expect(progress.totalBytes == UInt64(contents.count))
        }
        #expect(violationCount.withLock { $0 } == 0)
        #expect(localContents(destination) == contents)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(receipt.bytesTransferred == UInt64(contents.count))
        #expect(receipt.attempts == 1)
    }

    /// The protocol lets a server answer a READ with less than was asked
    /// anywhere in a file. Taken for end of file, every short reply
    /// committed a truncated download as a success.
    @Test("a server that reads short mid-file still delivers the whole file")
    func shortReadsAreNotEndOfFile() async throws {
        let rig = try await makeRig(configureServer: { $0.maximumReadReply = 100 })
        defer { teardown(rig) }
        let contents = (0..<3000).map { UInt8($0 % 241) }
        rig.fileSystem.createFile("/remote.bin", data: contents)
        let destination = rig.directory.appendingPathComponent("out.bin")

        let receipt = try await rig.engine.download(
            remotePath: "/remote.bin", to: destination, policy: .overwrite)
        #expect(localContents(destination) == contents)
        #expect(receipt.bytesTransferred == UInt64(contents.count))
    }

    @Test("a stated size over the download limit is refused before OPEN")
    func statedSizeOverLimit() async throws {
        let rig = try await makeRig { $0.maximumDownloadBytes = 1000 }
        defer { teardown(rig) }
        rig.fileSystem.createFile("/big", data: [UInt8](repeating: 1, count: 2000))
        let destination = rig.directory.appendingPathComponent("big")
        await #expect(throws: SFTPError.localIOFailed(operation: "download size limit", code: EFBIG)) {
            try await rig.engine.download(remotePath: "/big", to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!rig.server.log.operations.contains { $0.hasPrefix("open ") })
    }

    /// A server that states no size answers READs for as long as it likes.
    @Test("a download with no stated size stops at the limit")
    func unstatedSizeStopsAtLimit() async throws {
        let rig = try await makeRig { $0.maximumDownloadBytes = 1000 }
        defer { teardown(rig) }
        rig.fileSystem.createFile("/endless", data: [UInt8](repeating: 2, count: 4000))
        rig.server.interceptor = { message in
            if case .stat = message.payload {
                return .reply(.attrs(SFTPAttributes(permissions: 0o100_644, modificationTime: 1_000)))
            }
            return .proceed
        }
        let destination = rig.directory.appendingPathComponent("endless")
        await #expect(throws: SFTPError.localIOFailed(operation: "download size limit", code: EFBIG)) {
            try await rig.engine.download(remotePath: "/endless", to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.path + SFTPTransferEngine.partialSuffix))
    }

    @Test("a READ reply longer than requested is a protocol violation")
    func overlongReadReply() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote.bin", data: [UInt8](repeating: 3, count: 600))
        rig.server.interceptor = { message in
            if case .read(_, _, let length) = message.payload {
                return .reply(.data([UInt8](repeating: 4, count: Int(length) + 1)))
            }
            return .proceed
        }
        let destination = rig.directory.appendingPathComponent("out.bin")
        await #expect(throws: SFTPError.protocolViolation("READ reply longer than requested")) {
            try await rig.engine.download(remotePath: "/remote.bin", to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// `.fail` was checked once, before the transfer, and the commit was a
    /// plain `rename(2)`, which replaced a file that appeared meanwhile.
    @Test("the fail policy does not replace a destination that appeared mid-transfer")
    func failPolicyHoldsAtCommit() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1, 2, 3])
        let destination = rig.directory.appendingPathComponent("out")
        let path = destination.path
        rig.server.interceptor = { message in
            if case .read = message.payload, !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: Data([7]))
            }
            return .proceed
        }
        do {
            _ = try await rig.engine.download(remotePath: "/remote", to: destination, policy: .fail)
            Issue.record("the new destination should have failed the commit")
        } catch {
            #expect(error == .destinationConflict(path: path))
        }
        #expect(localContents(destination) == [7])
    }

    /// Every path is sent as a `String`'s UTF-8, so a name that is not
    /// valid UTF-8 cannot be addressed: its lossy form names another file.
    @Test("an unrelated partial is a conflict under the default download policy")
    func partialIsNotImplicitlyOwned() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1, 2, 3])
        let partial = try localFile(rig, "out.corta-part", contents: [9, 8, 7])
        let destination = rig.directory.appendingPathComponent("out")
        await #expect(throws: SFTPError.destinationConflict(path: partial.path)) {
            try await rig.engine.download(remotePath: "/remote", to: destination)
        }
        #expect(localContents(partial) == [9, 8, 7])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // An explicitly selected single-file overwrite still replaces a
        // partial the user chose; directory-wide consent cannot do this.
        try await rig.engine.download(remotePath: "/remote", to: destination, policy: .overwrite)
        #expect(localContents(destination) == [1, 2, 3])
    }

    @Test("a folder merge never consumes an unrelated partial under any blanket policy")
    func directoryPreservesUnrelatedPartial() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/tree/out", data: [1, 2, 3])
        let partial = try localFile(rig, "out.corta-part", contents: [9, 8, 7])
        for policy in [SFTPTransferEngine.ConflictPolicy.fail, .overwrite, .resume] {
            await #expect(throws: SFTPError.destinationConflict(path: partial.path)) {
                try await rig.engine.downloadDirectory(remotePath: "/tree", to: rig.directory, policy: policy)
            }
            #expect(localContents(partial) == [9, 8, 7])
        }
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent("out").path))
    }

    @Test("colliding remote tree names are rejected before any local file is changed")
    func directoryRejectsPartialNamespaceCollisions() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/tree/out", data: [1])
        rig.fileSystem.createFile("/tree/out.corta-part", data: [2])
        let existing = try localFile(rig, "out", contents: [9])
        let partial = rig.directory.appendingPathComponent("out.corta-part")
        await #expect(throws: SFTPError.destinationConflict(path: partial.path)) {
            try await rig.engine.downloadDirectory(remotePath: "/tree", to: rig.directory, policy: .overwrite)
        }
        #expect(localContents(existing) == [9])
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("a partial appearing after preflight cannot be truncated or unlinked")
    func racingPartialIsPreserved() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1])
        let partial = rig.directory.appendingPathComponent("out.corta-part")
        rig.server.interceptor = { message in
            if case .open = message.payload { try? Data([9]).write(to: partial) }
            return .proceed
        }
        await #expect(throws: SFTPError.destinationConflict(path: partial.path)) {
            try await rig.engine.download(remotePath: "/remote", to: rig.directory.appendingPathComponent("out"))
        }
        #expect(localContents(partial) == [9])
    }

    @Test("a directory download skips a name that is not UTF-8")
    func nonUTF8NamesAreSkipped() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createDirectory("/tree")
        let listed = Mutex(false)
        rig.server.interceptor = { message in
            guard case .readdir = message.payload else { return .proceed }
            let first = listed.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return .reply(.status(SFTPStatus(code: .endOfFile))) }
            return .reply(.name([
                SFTPEntry(
                    filename: [0x61, 0xFF, 0x62],
                    attributes: SFTPAttributes(size: 1, permissions: 0o100_644)),
            ]))
        }
        let target = rig.directory.appendingPathComponent("tree")
        let receipt = try await rig.engine.downloadDirectory(remotePath: "/tree", to: target)
        #expect(receipt.filesTransferred == 0)
        #expect(receipt.skipped.map(\.reason) == [.unsafeName])
    }

    @Test("file and directory downloads resume their own partial after transport failure", arguments: [false, true])
    func downloadResumesAfterTransportFailure(directoryTransfer: Bool) async throws {
        // The first server answers one READ, then drops the connection on
        // the second. The reconnect hook wires a fresh session to a second
        // server over the same filesystem — the app layer's role, in
        // miniature. The pipeline depth is 1 so the request order — and
        // therefore exactly how many bytes landed before the drop — is
        // deterministic.
        let fileSystem = FakeRemoteFileSystem()
        let contents = (0..<4096).map { UInt8($0 % 253) }
        let remote = directoryTransfer ? "/tree/big.bin" : "/big.bin"
        fileSystem.createFile(remote, data: contents, modificationTime: 4242)

        let firstConnection = SFTPLoopbackConnection()
        let firstServer = FakeSFTPServer(connection: firstConnection, fileSystem: fileSystem)
        let readCount = Mutex(0)
        firstServer.interceptor = { message in
            if case .read = message.payload {
                let thisRead = readCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if thisRead == 2 { return .dropConnection }
            }
            return .proceed
        }
        firstServer.start()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secondServerBox = Mutex<FakeSFTPServer?>(nil)
        let reconnect: SFTPTransferEngine.ReconnectHandler = {
            let connection = SFTPLoopbackConnection()
            let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
            server.start()
            secondServerBox.withLock { $0 = server }
            let session = SFTPSession(transport: connection.clientTransport())
            _ = try await session.connect()
            return session
        }

        let firstSession = SFTPSession(transport: firstConnection.clientTransport())
        _ = try await firstSession.connect()
        var configuration = SFTPTransferEngine.Configuration()
        configuration.blockSize = 512
        configuration.pipelineDepth = 1
        configuration.initialBackoff = .milliseconds(10)
        let engine = SFTPTransferEngine(
            session: firstSession, reconnect: reconnect, configuration: configuration)
        defer {
            engine.session.close()
            firstConnection.close()
        }

        let destination = directory.appendingPathComponent("big.bin")
        if directoryTransfer {
            let receipt = try await engine.downloadDirectory(remotePath: "/tree", to: directory, policy: .resume)
            #expect(receipt.filesTransferred == 1)
        } else {
            let receipt = try await engine.download(remotePath: remote, to: destination, policy: .resume)
            #expect(receipt.attempts == 2)
            #expect(receipt.resumedFromOffset == 512)
        }
        #expect(localContents(destination) == contents)

        // The second attempt's READs began exactly at the partial's size
        // — endpoint validation accepted the partial (its mtime records
        // the source's mtime of 4242). The lowest offset, not the first
        // logged: the engine issues a window of READs from concurrent
        // tasks, and which one the server sees first is the scheduler's
        // choice, not the engine's promise.
        let secondLog = try #require(secondServerBox.withLock { $0 }?.log)
        #expect(secondLog.readOffsets.min() == 512)
    }

    @Test("a changed source invalidates the partial and restarts from zero")
    func downloadRestartsWhenSourceChanged() async throws {
        let fileSystem = FakeRemoteFileSystem()
        // The source changed (mtime 4242 → 9999) since the partial began.
        let contents = (0..<2048).map { UInt8($0 % 241) }
        fileSystem.createFile("/big.bin", data: contents, modificationTime: 9999)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A stale partial: 1024 bytes, stamped with the *old* source mtime.
        let destination = directory.appendingPathComponent("big.bin")
        let partial = directory.appendingPathComponent("big.bin" + SFTPTransferEngine.partialSuffix)
        try Data(contents[0..<1024]).write(to: partial)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4242)], ofItemAtPath: partial.path)

        let connection = SFTPLoopbackConnection()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()
        var configuration = SFTPTransferEngine.Configuration()
        configuration.blockSize = 512
        let engine = SFTPTransferEngine(session: session, configuration: configuration)
        defer { session.close(); connection.close() }

        let receipt = try await engine.download(
            remotePath: "/big.bin", to: destination, policy: .resume)
        #expect(localContents(destination) == contents)
        // Endpoint validation rejected the stale partial: from zero. The
        // lowest READ offset is the evidence — the window's requests are
        // sent from concurrent tasks and arrive in no fixed order.
        #expect(receipt.resumedFromOffset == 0)
        #expect(server.log.readOffsets.min() == 0)
    }

    // MARK: - Conflict policy

    @Test("the fail policy refuses an existing destination before opening anything")
    func failPolicy() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1, 2, 3])
        let destination = try localFile(rig, "out", contents: [9, 9, 9])

        do {
            _ = try await rig.engine.download(remotePath: "/remote", to: destination, policy: .fail)
            Issue.record("the conflict should have failed the transfer")
        } catch {
            #expect(error == .destinationConflict(path: destination.path))
        }
        #expect(localContents(destination) == [9, 9, 9])
        // The source stat for the conflict context is all the server saw.
        #expect(rig.server.log.operations == ["stat /remote"])
    }

    @Test("the overwrite policy replaces the destination")
    func overwritePolicy() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1, 2, 3])
        let destination = try localFile(rig, "out", contents: [9, 9, 9])

        try await rig.engine.download(remotePath: "/remote", to: destination, policy: .overwrite)
        #expect(localContents(destination) == [1, 2, 3])
    }

    @Test("downloads are quarantined only when the engine is configured to")
    func quarantinedDownloads() async throws {
        func quarantine(_ url: URL) -> String? {
            let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            _ = getxattr(url.path, "com.apple.quarantine", &bytes, size, 0, 0)
            return String(decoding: bytes, as: UTF8.self)
        }
        let marked = try await makeRig { $0.quarantinesDownloads = true }
        defer { teardown(marked) }
        marked.fileSystem.createFile("/tool.command", data: [1, 2, 3])
        let destination = marked.directory.appendingPathComponent("tool.command")
        try await marked.engine.download(remotePath: "/tool.command", to: destination)
        let mark = try #require(quarantine(destination))
        let fields = mark.split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count == 4)
        // LaunchServices can omit the agent name for a headless test
        // executable. Assert the actual download mark, not that display name.
        let flags = try #require(fields.first.flatMap { UInt16($0, radix: 16) })
        #expect(flags & 1 != 0)
        #expect(fields.count > 1 && UInt64(fields[1], radix: 16) != nil)

        let plain = try await makeRig()
        defer { teardown(plain) }
        plain.fileSystem.createFile("/tool.command", data: [1, 2, 3])
        let unmarked = plain.directory.appendingPathComponent("tool.command")
        try await plain.engine.download(remotePath: "/tool.command", to: unmarked)
        #expect(quarantine(unmarked) == nil)
    }

    @Test("the decide policy receives the conflict and its decision is honoured")
    func decidePolicy() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [1, 2, 3])
        let destination = try localFile(rig, "out", contents: [9, 9, 9])

        final class Seen: @unchecked Sendable {
            var conflict: SFTPTransferEngine.SFTPConflict?
        }
        let seen = Seen()
        do {
            _ = try await rig.engine.download(
                remotePath: "/remote", to: destination,
                policy: .decide { conflict in
                    seen.conflict = conflict
                    return .fail
                })
            Issue.record("the decided .fail should have failed the transfer")
        } catch {
            guard case SFTPError.destinationConflict = error else {
                Issue.record("expected a conflict error, got \(error)")
                return
            }
        }
        #expect(seen.conflict?.destinationExists == true)
        #expect(seen.conflict?.sourceSize == 3)
        #expect(localContents(destination) == [9, 9, 9])
    }

    // MARK: - Upload

    @Test("an upload writes only the partial and commits with an atomic rename")
    func uploadIsAtomic() async throws {
        let rig = try await makeRig(configureServer: { server in
            server.advertisedExtensions = [SFTPCodec.posixRenameExtensionName]
        })
        defer { teardown(rig) }
        let contents = (0..<2048).map { UInt8($0 % 247) }
        let source = try localFile(rig, "up.bin", contents: contents)

        try await rig.engine.upload(from: source, to: "/dest/up.bin", policy: .overwrite)

        let partialPath = "/dest/up.bin" + rig.partialName
        let log = rig.server.log
        // Every WRITE targeted the partial; the destination name appears
        // only in the final posix-rename, after the partial's CLOSE.
        #expect(!log.writePaths.isEmpty)
        #expect(log.writePaths.allSatisfy { $0 == partialPath })
        let closeIndex = log.operations.firstIndex(of: "close")
        let renameIndex = log.operations.firstIndex(
            of: "extended \(SFTPCodec.posixRenameExtensionName)")
        #expect(closeIndex != nil && renameIndex != nil && closeIndex! < renameIndex!)
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == contents)
        #expect(!rig.fileSystem.exists(partialPath))
    }

    /// `posix-rename` replaces its destination, so under `.fail` the commit
    /// is version 3's RENAME, which refuses one that appeared after the check.
    @Test("an upload under the fail policy commits without replacing")
    func uploadFailPolicyHoldsAtCommit() async throws {
        let rig = try await makeRig(configureServer: { server in
            server.advertisedExtensions = [SFTPCodec.posixRenameExtensionName]
        })
        defer { teardown(rig) }
        let source = try localFile(rig, "up.bin", contents: [1, 2, 3, 4])
        let fileSystem = rig.fileSystem
        rig.server.interceptor = { message in
            if case .write = message.payload, !fileSystem.exists("/dest/up.bin") {
                fileSystem.createFile("/dest/up.bin", data: [0xee])
            }
            return .proceed
        }
        do {
            _ = try await rig.engine.upload(from: source, to: "/dest/up.bin", policy: .fail)
            Issue.record("the new destination should have failed the commit")
        } catch {
            guard case SFTPError.server = error else {
                Issue.record("expected the server's refusal, got \(error)")
                return
            }
        }
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == [0xee])
        #expect(!rig.server.log.operations.contains("extended \(SFTPCodec.posixRenameExtensionName)"))
    }

    @Test("without posix-rename, overwriting renames the old file aside until the new one is in place")
    func uploadOverwriteFallback() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/dest/up.bin", data: [0xee])
        let source = try localFile(rig, "up.bin", contents: [1, 2, 3, 4])

        try await rig.engine.upload(from: source, to: "/dest/up.bin", policy: .overwrite)
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == [1, 2, 3, 4])
        let log = rig.server.log.operations
        // The old file is never removed before the new one has its name:
        // aside first, the partial into place, then the old copy removed.
        let aside = try #require(
            log.first { $0.hasPrefix("rename /dest/up.bin -> /dest/up.bin.corta-old-") })
        let asidePath = String(aside.dropFirst("rename /dest/up.bin -> ".count))
        let asideIndex = try #require(log.firstIndex(of: aside))
        let commitIndex = try #require(
            log.lastIndex(of: "rename /dest/up.bin\(rig.partialName) -> /dest/up.bin"))
        let removeIndex = try #require(log.firstIndex(of: "remove \(asidePath)"))
        #expect(asideIndex < commitIndex && commitIndex < removeIndex)
        #expect(!log.contains("remove /dest/up.bin"))
        #expect(!rig.fileSystem.exists(asidePath))
    }

    /// The fallback used to REMOVE the destination and then RENAME; when the
    /// second step failed, the failure cleanup removed the partial too, and
    /// neither the old file nor the new one was left anywhere.
    @Test("a failed fallback commit puts the old file back")
    func failedFallbackCommitRestoresDestination() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: Array("ORIGINAL".utf8))
        let source = try localFile(rig, "new", contents: Array("NEW".utf8))
        let partialPath = "/remote" + rig.partialName
        rig.server.interceptor = { message in
            if case .rename(let old, _) = message.payload,
                String(decoding: old, as: UTF8.self) == partialPath
            {
                return .reply(.status(SFTPStatus(
                    code: .failure, message: Array("refused".utf8), languageTag: Array("en".utf8))))
            }
            return .proceed
        }
        await #expect(throws: SFTPError.self) {
            try await rig.engine.upload(
                from: source, to: "/remote", policy: .overwrite, partialDisposition: .remove)
        }
        #expect(rig.fileSystem.file("/remote")?.data == Array("ORIGINAL".utf8))
        #expect(rig.fileSystem.children(of: "/") == ["remote"])
    }

    @Test("a fallback commit that cannot be undone says where both copies are")
    func unrecoverableFallbackCommitKeepsBothCopies() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: Array("ORIGINAL".utf8))
        let source = try localFile(rig, "new", contents: Array("NEW".utf8))
        let partialPath = "/remote" + rig.partialName
        rig.server.interceptor = { message in
            if case .rename(let old, _) = message.payload {
                let name = String(decoding: old, as: UTF8.self)
                if name == partialPath || name.hasPrefix("/remote.corta-old-") {
                    return .reply(.status(SFTPStatus(
                        code: .failure, message: Array("refused".utf8),
                        languageTag: Array("en".utf8))))
                }
            }
            return .proceed
        }
        // Bound outside the catch: see `firstConnectRefusalIsClassified`.
        var caught: SFTPError?
        do {
            _ = try await rig.engine.upload(
                from: source, to: "/remote", policy: .overwrite, partialDisposition: .remove)
        } catch {
            caught = error
        }
        guard case .replaceIncomplete(let destination, let previous, let new)? = caught else {
            Issue.record("expected replaceIncomplete, got \(String(describing: caught))")
            return
        }
        #expect(destination == "/remote")
        #expect(new == partialPath)
        #expect(rig.fileSystem.file(previous)?.data == Array("ORIGINAL".utf8))
        #expect(rig.fileSystem.file(new)?.data == Array("NEW".utf8))
    }

    /// Two overwrites of one path shared its partial: the second truncated
    /// and committed it while the first still wrote through its own handle,
    /// so a destination reported done went on changing.
    @Test("transfers to one destination take turns, across engines of one scope")
    func sameDestinationTransfersAreSerialised() async throws {
        let scope = "box-\(UUID().uuidString)"
        let rig = try await makeRig(configureEngine: {
            $0.destinationScope = scope
            $0.pipelineDepth = 1
        })
        defer { teardown(rig) }
        var configuration = rig.engine.configuration
        configuration.destinationScope = scope
        let other = SFTPTransferEngine(session: rig.session, configuration: configuration)
        let first = try localFile(rig, "a", contents: [UInt8](repeating: 0x41, count: 2048))
        let second = try localFile(rig, "b", contents: [UInt8](repeating: 0x42, count: 512))

        let firstPaused = Mutex(false)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstTask = Task {
            try await rig.engine.upload(from: first, to: "/target", policy: .overwrite) { _ in
                if !firstPaused.withLock({ $0 }) {
                    firstPaused.withLock { $0 = true }
                    _ = releaseFirst.wait(timeout: .now() + 5)
                }
            }
        }
        #expect(try await waitForFlag(firstPaused))
        let secondFinished = Mutex(false)
        let secondTask = Task {
            defer { secondFinished.withLock { $0 = true } }
            return try await other.upload(from: second, to: "/target", policy: .overwrite)
        }
        try await Task.sleep(for: .milliseconds(200))
        // The second waits for the path; it has not opened anything.
        #expect(!secondFinished.withLock { $0 })
        #expect(!rig.fileSystem.exists("/target"))
        releaseFirst.signal()
        _ = try await firstTask.value
        _ = try await secondTask.value
        // Last writer wins, whole: the destination is the second file, not
        // the first's tail written over it.
        #expect(rig.fileSystem.file("/target")?.data == [UInt8](repeating: 0x42, count: 512))
        #expect(!SFTPDestinationLocks.shared.isHeld(rig.engine.remoteClaim("/target")))
        // One path, however it is spelled.
        #expect(rig.engine.remoteClaim("//target") == rig.engine.remoteClaim("/target"))
        #expect(SFTPDestinationLocks.normalizedRemotePath("/a//b/./c/../d") == "/a/b/d")
        #expect(SFTPDestinationLocks.normalizedRemotePath("rel/./x") == "rel/x")
    }

    @Test("a download whose source shrinks mid-transfer fails and keeps the destination")
    func shrunkDownloadSourceFails() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [UInt8](repeating: 7, count: 2048))
        let destination = try localFile(rig, "out", contents: Array("ORIGINAL".utf8))
        let fileSystem = rig.fileSystem
        let shrunk = Mutex(false)
        rig.server.interceptor = { message in
            if case .read = message.payload, !shrunk.withLock({ $0 }) {
                shrunk.withLock { $0 = true }
                fileSystem.createFile("/remote", data: [UInt8](repeating: 7, count: 100))
            }
            return .proceed
        }
        await #expect(throws: SFTPError.sourceChanged(path: "/remote")) {
            try await rig.engine.download(remotePath: "/remote", to: destination, policy: .overwrite)
        }
        #expect(localContents(destination) == Array("ORIGINAL".utf8))
    }

    @Test("a download whose source is rewritten mid-transfer fails")
    func rewrittenDownloadSourceFails() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: [UInt8](repeating: 7, count: 2048))
        let destination = rig.directory.appendingPathComponent("out")
        let fileSystem = rig.fileSystem
        rig.server.interceptor = { message in
            if case .read = message.payload, fileSystem.file("/remote")?.modificationTime == 1_000 {
                fileSystem.createFile(
                    "/remote", data: [UInt8](repeating: 8, count: 2048), modificationTime: 2_000)
            }
            return .proceed
        }
        await #expect(throws: SFTPError.sourceChanged(path: "/remote")) {
            try await rig.engine.download(remotePath: "/remote", to: destination, policy: .overwrite)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("an upload whose source shrinks or grows mid-transfer fails and keeps the destination",
        arguments: [100, 4096])
    func changedUploadSourceFails(newSize: Int) async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/remote", data: Array("ORIGINAL".utf8))
        let source = try localFile(rig, "up", contents: [UInt8](repeating: 3, count: 2048))
        let changed = Mutex(false)
        rig.server.interceptor = { message in
            if case .open = message.payload, !changed.withLock({ $0 }) {
                changed.withLock { $0 = true }
                try? Data(repeating: 4, count: newSize).write(to: source)
            }
            return .proceed
        }
        await #expect(throws: SFTPError.self) {
            try await rig.engine.upload(from: source, to: "/remote", policy: .overwrite)
        }
        #expect(rig.fileSystem.file("/remote")?.data == Array("ORIGINAL".utf8))
        #expect(!rig.fileSystem.exists("/remote" + rig.partialName))
    }

    /// A real server moves the partial's mtime on every WRITE, so the stamp
    /// set at OPEN was gone by the time a cancel kept the partial, and the
    /// retry restarted from zero.
    @Test("a cancelled upload's partial resumes on a server whose WRITE moves the mtime")
    func cancelledUploadResumesDespiteWriteStamps() async throws {
        let rig = try await makeRig(configureEngine: { $0.pipelineDepth = 1 })
        defer { teardown(rig) }
        let contents = (0..<2048).map { UInt8($0 % 229) }
        let source = try localFile(rig, "up", contents: contents, mtime: 7777)
        let partialPath = "/remote" + rig.partialName
        let fileSystem = rig.fileSystem
        rig.server.interceptor = { message in
            if case .write = message.payload, var file = fileSystem.file(partialPath) {
                file.modificationTime = 99_999
                fileSystem.createFile(partialPath, data: file.data, modificationTime: 99_999)
            }
            return .proceed
        }
        let wrote = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let transfer = Task {
            try await rig.engine.upload(
                from: source, to: "/remote", policy: .resume, partialDisposition: .keepForResume
            ) { _ in
                wrote.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 5)
            }
        }
        #expect(try await waitForFlag(wrote))
        transfer.cancel()
        release.signal()
        await #expect(throws: SFTPError.cancelled) { try await transfer.value }
        // The cleanup put the source's mtime back on what it kept.
        #expect(rig.fileSystem.file(partialPath)?.modificationTime == 7777)
        #expect((rig.fileSystem.file(partialPath)?.data.count ?? 0) > 0)

        // A different engine — no memory of the first — trusts the stamp.
        let fresh = SFTPTransferEngine(session: rig.session, configuration: rig.engine.configuration)
        rig.server.interceptor = nil
        let receipt = try await fresh.upload(from: source, to: "/remote", policy: .resume)
        #expect(receipt.resumedFromOffset > 0)
        #expect(rig.fileSystem.file("/remote")?.data == contents)
    }

    @Test("an upload retried after a lost connection resumes its own partial")
    func uploadResumesAfterTransportFailure() async throws {
        let fileSystem = FakeRemoteFileSystem()
        let contents = (0..<4096).map { UInt8($0 % 227) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("up")
        try Data(contents).write(to: source)
        let partialPath = "/remote" + SFTPTransferEngine.partialSuffix

        let firstConnection = SFTPLoopbackConnection()
        let firstServer = FakeSFTPServer(connection: firstConnection, fileSystem: fileSystem)
        let writes = Mutex(0)
        firstServer.interceptor = { message in
            if case .write = message.payload {
                // Every WRITE moves the mtime, as a real server's does.
                if let file = fileSystem.file(partialPath) {
                    fileSystem.createFile(partialPath, data: file.data, modificationTime: 99_999)
                }
                let count = writes.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 3 { return .dropConnection }
            }
            return .proceed
        }
        firstServer.start()
        let reconnect: SFTPTransferEngine.ReconnectHandler = {
            let connection = SFTPLoopbackConnection()
            let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
            server.start()
            let session = SFTPSession(transport: connection.clientTransport())
            _ = try await session.connect()
            return session
        }
        let firstSession = SFTPSession(transport: firstConnection.clientTransport())
        _ = try await firstSession.connect()
        var configuration = SFTPTransferEngine.Configuration()
        configuration.blockSize = 512
        configuration.pipelineDepth = 1
        configuration.initialBackoff = .milliseconds(10)
        let engine = SFTPTransferEngine(
            session: firstSession, reconnect: reconnect, configuration: configuration)
        defer {
            engine.session.close()
            firstConnection.close()
        }
        let receipt = try await engine.upload(from: source, to: "/remote", policy: .resume)
        #expect(receipt.attempts == 2)
        #expect(receipt.resumedFromOffset == 1024)
        #expect(fileSystem.file("/remote")?.data == contents)
    }

    @Test("a folder that is gone when its upload starts fails instead of uploading nothing")
    func missingUploadDirectoryFails() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        let missing = rig.directory.appendingPathComponent("MISSING")
        await #expect(throws: SFTPError.localIOFailed(operation: "opendir", code: ENOENT)) {
            try await rig.engine.uploadDirectory(from: missing, to: "/backup", policy: .overwrite)
        }
        #expect(!rig.fileSystem.exists("/backup"))
        let file = try localFile(rig, "plain", contents: [1])
        await #expect(throws: SFTPError.localIOFailed(operation: "opendir", code: ENOTDIR)) {
            try await rig.engine.uploadDirectory(from: file, to: "/backup", policy: .overwrite)
        }
        // A folder that is really empty still uploads as one.
        let empty = rig.directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let receipt = try await rig.engine.uploadDirectory(from: empty, to: "/backup", policy: .overwrite)
        #expect(receipt.filesTransferred == 0)
        #expect(rig.fileSystem.isDirectory("/backup"))
    }

    @Test("an upload resumes at the remote partial's size")
    func uploadResumes() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        let contents = (0..<2048).map { UInt8($0 % 239) }
        let source = try localFile(rig, "up.bin", contents: contents, mtime: 7777)
        // The interrupted upload's partial: first 1024 bytes, stamped with
        // the source's mtime by the interrupted run's FSETSTAT.
        let partialPath = "/dest/up.bin" + rig.partialName
        rig.fileSystem.createFile(
            partialPath, data: Array(contents[0..<1024]), modificationTime: 7777)

        let receipt = try await rig.engine.upload(
            from: source, to: "/dest/up.bin", policy: .resume)
        #expect(receipt.resumedFromOffset == 1024)
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == contents)
        // The writes continued where the partial ended: nothing below
        // 1024 was written, and the block at 1024 was. Not "the first
        // logged write" — the window's requests are sent from concurrent
        // tasks and arrive in no fixed order.
        let writeOps = rig.server.log.operations.filter { $0.hasPrefix("write @") }
        #expect(writeOps.contains("write @1024 512b"))
        #expect(!writeOps.contains { $0.hasPrefix("write @0 ") || $0.hasPrefix("write @512 ") })
    }

    @Test("a changed local source restarts the upload from zero")
    func uploadRestartsWhenSourceChanged() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        let contents = (0..<2048).map { UInt8($0 % 233) }
        // The source's mtime (5555) no longer matches the partial's record.
        let source = try localFile(rig, "up.bin", contents: contents, mtime: 5555)
        let partialPath = "/dest/up.bin" + rig.partialName
        rig.fileSystem.createFile(
            partialPath, data: Array(contents[0..<1024]), modificationTime: 7777)

        let receipt = try await rig.engine.upload(
            from: source, to: "/dest/up.bin", policy: .resume)
        #expect(receipt.resumedFromOffset == 0)
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == contents)
        #expect(rig.server.log.operations.contains { $0.hasPrefix("write @0 ") })
    }

    // MARK: - Cancellation

    @Test("cancelling a download aborts it, closes the handle, and keeps or drops the partial per policy")
    func cancellationMidDownload() async throws {
        let rig = try await makeRig(configureServer: { server in
            server.replyDelay = .milliseconds(30)
        })
        defer { teardown(rig) }
        rig.fileSystem.createFile("/big.bin", data: [UInt8](repeating: 0x77, count: 1 << 20))

        let destination = rig.directory.appendingPathComponent("big.bin")
        let partial = rig.directory.appendingPathComponent("big.bin" + rig.partialName)

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var seen = false
            func mark() { lock.lock(); seen = true; lock.unlock() }
            var wasSeen: Bool { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let progress = Progress()

        let task = Task {
            try await rig.engine.download(
                remotePath: "/big.bin", to: destination, policy: .overwrite
            ) { _ in progress.mark() }
        }
        // Wait for the transfer to actually be mid-flight, then cancel.
        let deadline = Date().addingTimeInterval(testTimeoutInterval(15))
        while !progress.wasSeen, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(progress.wasSeen)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("the cancelled download should have thrown")
        } catch {
            #expect(error as? SFTPError == .cancelled)
        }
        // No partial content ever reached the destination name; the
        // overwrite policy removed the partial; the server saw CLOSE.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(
            rig.server.waitFor("the close of the aborted handle") { $0.closeCount >= 1 })
    }

    @Test("a cancelled resume-policy download keeps its partial for later")
    func cancellationKeepsPartialForResume() async throws {
        let rig = try await makeRig(configureServer: { server in
            server.replyDelay = .milliseconds(30)
        })
        defer { teardown(rig) }
        rig.fileSystem.createFile("/big.bin", data: [UInt8](repeating: 0x66, count: 1 << 20))

        let destination = rig.directory.appendingPathComponent("big.bin")
        let partial = rig.directory.appendingPathComponent("big.bin" + rig.partialName)

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var seen = false
            func mark() { lock.lock(); seen = true; lock.unlock() }
            var wasSeen: Bool { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let progress = Progress()
        let task = Task {
            try await rig.engine.download(
                remotePath: "/big.bin", to: destination, policy: .resume
            ) { _ in progress.mark() }
        }
        let deadline = Date().addingTimeInterval(testTimeoutInterval(15))
        while !progress.wasSeen, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        _ = try? await task.value

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let kept = localContents(partial)
        #expect(kept != nil && !kept!.isEmpty)
    }

    // MARK: - Directory listing

    @Test("listDirectory assembles entries across multiple READDIR batches")
    func listingAcrossBatches() async throws {
        let rig = try await makeRig(
            configureEngine: { $0.maximumDirectoryEntries = 5 },
            configureServer: { $0.readDirBatchSize = 2 })
        defer { teardown(rig) }
        for index in 0..<5 {
            rig.fileSystem.createFile("/dir/file-\(index).txt", data: [UInt8(index)])
        }

        let entries = try await rig.engine.listDirectory(path: "/dir")
        #expect(entries.map { $0.filenameUTF8 }.sorted()
            == (0..<5).map { "file-\($0).txt" })
        // Five entries, two per batch: batches of 2, 2 and 1, then the
        // READDIR that is answered EOF.
        #expect(rig.server.log.operations.filter { $0 == "readdir" }.count == 4)
    }

    @Test("listDirectory closes the handle even when a batch fails")
    func listingFailureClosesHandle() async throws {
        let rig = try await makeRig(configureServer: { server in
            server.readDirBatchSize = 2
        })
        defer { teardown(rig) }
        for index in 0..<9 {
            rig.fileSystem.createFile("/dir/f\(index)", data: [])
        }
        let batchNumber = Mutex(0)
        rig.server.interceptor = { message in
            if case .readdir = message.payload {
                let this = batchNumber.withLock { count -> Int in
                    count += 1
                    return count
                }
                if this == 2 {
                    return .reply(.status(SFTPStatus(code: .failure, message: Array("boom".utf8))))
                }
            }
            return .proceed
        }
        do {
            _ = try await rig.engine.listDirectory(path: "/dir")
            Issue.record("the listing should have failed")
        } catch {
            guard case SFTPError.server(let status) = error else {
                Issue.record("expected a server status, got \(error)")
                return
            }
            #expect(status.code == .failure)
        }
        #expect(
            rig.server.waitFor("the failed listing's close") { $0.closeCount >= 1 })
    }

    // MARK: - Concurrency queue

    @Test("admission rechecks capacity and cancellation before registering a waiter")
    func admissionRegistrationRaces() async throws {
        for cancelBeforeRegistration in [false, true] {
            let rig = try await makeRig(configureEngine: {
                $0.maxConcurrentTransfers = 1
                $0.pipelineDepth = 1
            })
            defer { teardown(rig) }
            rig.fileSystem.createFile("/file", data: [1])
            let firstAtProgress = Mutex(false)
            let secondAtAdmission = Mutex(false)
            let releaseFirst = DispatchSemaphore(value: 0)
            let releaseSecond = DispatchSemaphore(value: 0)
            rig.engine.transferAdmissionGate = {
                secondAtAdmission.withLock { $0 = true }
                _ = releaseSecond.wait(timeout: .now() + 5)
            }
            let first = Task {
                try await rig.engine.download(
                    remotePath: "/file", to: rig.directory.appendingPathComponent("first")) { _ in
                    firstAtProgress.withLock { $0 = true }
                    _ = releaseFirst.wait(timeout: .now() + 5)
                }
            }
            #expect(try await waitForFlag(firstAtProgress))
            let secondFinished = Mutex(false)
            let second = Task {
                defer { secondFinished.withLock { $0 = true } }
                return try await rig.engine.download(
                    remotePath: "/file", to: rig.directory.appendingPathComponent("second"))
            }
            #expect(try await waitForFlag(secondAtAdmission))
            if cancelBeforeRegistration {
                second.cancel()
                releaseSecond.signal()
            } else {
                releaseFirst.signal()
                _ = try await first.value  // Last running slot released before registration.
                releaseSecond.signal()
            }
            let completed = try await waitForFlag(secondFinished)
            #expect(completed, "registration must not lose a release or earlier cancellation")
            if !completed { second.cancel() }
            do {
                _ = try await second.value
                #expect(!cancelBeforeRegistration)
            } catch {
                #expect(cancelBeforeRegistration)
                #expect(error as? SFTPError == .cancelled)
            }
            if cancelBeforeRegistration {
                releaseFirst.signal()
                _ = try await first.value
            }
        }
    }

    private func waitForFlag(_ flag: borrowing Mutex<Bool>) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !flag.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return flag.withLock { $0 }
    }

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
