import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

/// B14 — the transfer engine against the scripted fake server: atomic
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

    @Test("a download interrupted mid-transfer resumes from the partial's size")
    func downloadResumesAfterTransportFailure() async throws {
        // The first server answers one READ, then drops the connection on
        // the second. The reconnect hook wires a fresh session to a second
        // server over the same filesystem — the app layer's role, in
        // miniature. The pipeline depth is 1 so the request order — and
        // therefore exactly how many bytes landed before the drop — is
        // deterministic.
        let fileSystem = FakeRemoteFileSystem()
        let contents = (0..<4096).map { UInt8($0 % 253) }
        fileSystem.createFile("/big.bin", data: contents, modificationTime: 4242)

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
        let receipt = try await engine.download(
            remotePath: "/big.bin", to: destination, policy: .resume)
        #expect(localContents(destination) == contents)
        #expect(receipt.attempts == 2)
        #expect(receipt.resumedFromOffset == 512)

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

        try await rig.engine.upload(from: source, to: "/dest/up.bin", policy: .fail)

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

    @Test("without posix-rename, overwriting falls back to remove then rename")
    func uploadOverwriteFallback() async throws {
        let rig = try await makeRig()
        defer { teardown(rig) }
        rig.fileSystem.createFile("/dest/up.bin", data: [0xee])
        let source = try localFile(rig, "up.bin", contents: [1, 2, 3, 4])

        try await rig.engine.upload(from: source, to: "/dest/up.bin", policy: .overwrite)
        #expect(rig.fileSystem.file("/dest/up.bin")?.data == [1, 2, 3, 4])
        let log = rig.server.log.operations
        let removeIndex = log.firstIndex(of: "remove /dest/up.bin")
        // The first rename attempt fails (destination exists) and is what
        // the fallback reacts to; the successful one is the last.
        let renameIndex = log.lastIndex(
            of: "rename /dest/up.bin\(rig.partialName) -> /dest/up.bin")
        #expect(removeIndex != nil && renameIndex != nil && removeIndex! < renameIndex!)
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
        let rig = try await makeRig(configureServer: { server in
            server.readDirBatchSize = 2
        })
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
