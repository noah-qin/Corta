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

extension SFTPTransferTests {
    /// Answers the first READ and drops the connection on the second.
    static func droppingOnSecondRead() -> @Sendable (SFTPMessage) -> FakeServerAction {
        let readCount = Mutex(0)
        return { message in
            if case .read = message.payload {
                let thisRead = readCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if thisRead == 2 { return .dropConnection }
            }
            return .proceed
        }
    }

    /// A reconnect that wires a fresh session to a second server over the
    /// same filesystem — the app layer's role, in miniature — and the server
    /// it last started, which it keeps alive.
    static func reconnecting(
        to fileSystem: FakeRemoteFileSystem
    ) -> (SFTPTransferEngine.ReconnectHandler, @Sendable () -> FakeSFTPServer?) {
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
        return (reconnect, { secondServerBox.withLock { $0 } })
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
        firstServer.interceptor = Self.droppingOnSecondRead()
        firstServer.start()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (reconnect, secondServer) = Self.reconnecting(to: fileSystem)

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
        let secondLog = try #require(secondServer()?.log)
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
}
