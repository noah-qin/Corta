import Foundation
import Testing

@testable import CortaTerminal

/// B14 — the session against the scripted fake server over the in-memory
/// loopback: handshake and capabilities, request/response plumbing, the
/// in-flight window bound, cancellation of in-flight requests, and
/// teardown on protocol violations.
@Suite("SFTP session", .serialized)
struct SFTPSessionTests {
    /// Builds a connected session + server pair over a fresh loopback.
    private func makePair(
        configure: (FakeSFTPServer) -> Void = { _ in }
    ) async throws -> (SFTPSession, FakeSFTPServer, FakeRemoteFileSystem) {
        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        configure(server)
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()
        return (session, server, fileSystem)
    }

    @Test("connect negotiates version 3 and reports advertised capabilities")
    func handshakeCapabilities() async throws {
        let (session, _, _) = try await makePair { server in
            server.advertisedExtensions = [
                SFTPCodec.statVFSExtensionName, SFTPCodec.posixRenameExtensionName,
            ]
        }
        defer { session.close() }
        let capabilities = try #require(session.capabilities)
        #expect(capabilities.version == 3)
        #expect(capabilities.supportsStatVFS)
        #expect(capabilities.supportsPosixRename)
    }

    @Test("a server without extensions reports both capabilities unavailable")
    func noCapabilitiesGuessed() async throws {
        let (session, _, _) = try await makePair()
        defer { session.close() }
        let capabilities = try #require(session.capabilities)
        #expect(!capabilities.supportsStatVFS)
        #expect(!capabilities.supportsPosixRename)
        // Degradation is explicit: volume info is unavailable, not zero.
        #expect(try await session.volumeInfo() == nil)
    }

    @Test("statvfs round-trips when the server speaks it")
    func statVFS() async throws {
        let (session, _, _) = try await makePair { server in
            server.advertisedExtensions = [SFTPCodec.statVFSExtensionName]
        }
        defer { session.close() }
        let info = try await #require(session.volumeInfo(path: "/"))
        #expect(info.blocks == 1000)
        #expect(info.blocksAvailable == 400)
        #expect(info.nameMaximum == 255)
    }

    @Test("an advertised-but-refused statvfs degrades to unavailable")
    func statVFSRefused() async throws {
        let (session, _, _) = try await makePair { server in
            server.advertisedExtensions = [SFTPCodec.statVFSExtensionName]
            server.statVFSReply = nil
        }
        defer { session.close() }
        #expect(try await session.volumeInfo() == nil)
    }

    @Test("open, write, read, close round-trip file contents")
    func fileRoundTrip() async throws {
        let (session, _, fileSystem) = try await makePair()
        defer { session.close() }

        let handle = try await session.open(
            path: "/note.txt", flags: [.write, .create, .truncate])
        try await session.write(handle: handle, offset: 0, data: Array("hello ".utf8))
        try await session.write(handle: handle, offset: 6, data: Array("sftp".utf8))
        try await session.close(handle)

        let reader = try await session.open(path: "/note.txt", flags: .read)
        let first = try await session.read(handle: reader, offset: 0, length: 6)
        #expect(first == Array("hello ".utf8))
        let rest = try await session.read(handle: reader, offset: 6, length: 64)
        #expect(rest == Array("sftp".utf8))
        // Past the end the server answers EOF, surfaced as empty data.
        #expect(try await session.read(handle: reader, offset: 10, length: 1) == [])
        try await session.close(reader)

        #expect(fileSystem.file("/note.txt")?.data == Array("hello sftp".utf8))
    }

    @Test("a refused open surfaces the server's status, not a transport error")
    func permissionDenied() async throws {
        let (session, server, _) = try await makePair()
        server.refusedPaths = ["/secret"]
        defer { session.close() }
        do {
            _ = try await session.open(path: "/secret", flags: .read)
            Issue.record("the open should have failed")
        } catch {
            // Plain `catch` plus a pattern guard: typed-throws catch
            // patterns crash this toolchain's SIL verifier.
            guard case SFTPError.server(let status) = error else {
                Issue.record("expected a server status, got \(error)")
                return
            }
            #expect(status.code == .permissionDenied)
            #expect(status.messageString == "refused by the test")
        }
    }

    @Test("stat, rename and remove behave against the filesystem")
    func metadataOperations() async throws {
        let (session, _, fileSystem) = try await makePair()
        defer { session.close() }
        fileSystem.createFile("/a.txt", data: Array("abc".utf8), modificationTime: 4242)

        let attributes = try await session.stat(path: "/a.txt")
        #expect(attributes.size == 3)
        #expect(attributes.modificationTime == 4242)

        try await session.rename(from: "/a.txt", to: "/b.txt")
        #expect(fileSystem.file("/a.txt") == nil)
        #expect(fileSystem.file("/b.txt")?.data == Array("abc".utf8))

        try await session.remove(path: "/b.txt")
        #expect(!fileSystem.exists("/b.txt"))

        do {
            _ = try await session.stat(path: "/b.txt")
            Issue.record("stat of a removed file should fail")
        } catch {
            guard case SFTPError.server(let status) = error else {
                Issue.record("expected a server status, got \(error)")
                return
            }
            #expect(status.code == .noSuchFile)
        }
    }

    @Test("the in-flight window bounds concurrent requests")
    func windowBound() async throws {
        let (session, server, fileSystem) = try await makePair { server in
            server.replyDelay = .milliseconds(50)
        }
        defer { session.close() }
        fileSystem.createFile("/big", data: [UInt8](repeating: 0x61, count: 4096))

        let handle = try await session.open(path: "/big", flags: .read)
        // Fire far more reads than the window admits; each is tiny, the
        // server delays, and the high-water mark is the test's evidence.
        try await withThrowingTaskGroup(of: [UInt8].self) { group in
            for index in 0..<96 {
                group.addTask {
                    try await session.read(
                        handle: handle, offset: UInt64(index % 8), length: 1)
                }
            }
            for try await _ in group {}
        }
        try await session.close(handle)
        #expect(server.log.maxOutstandingReads > 1)
        #expect(server.log.maxOutstandingReads <= 32)
    }

    @Test("cancelling an in-flight request resumes it cancelled and the session survives")
    func requestCancellation() async throws {
        let (session, server, fileSystem) = try await makePair { server in
            server.replyDelay = .milliseconds(500)
        }
        defer { session.close() }
        fileSystem.createFile("/big", data: [UInt8](repeating: 0x62, count: 64))
        let handle = try await session.open(path: "/big", flags: .read)

        let task = Task {
            try await session.read(handle: handle, offset: 0, length: 8)
        }
        // Let the request reach the server, then cancel.
        #expect(server.waitFor("the read to arrive") { $0.readOffsets == [0] })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled read should throw")
        } catch {
            #expect(error as? SFTPError == .cancelled)
        }

        // The session is still usable — the late reply is swallowed and
        // the request-id recycled, not mistaken for a protocol violation.
        let data = try await session.read(handle: handle, offset: 0, length: 4)
        #expect(data == Array("bbbb".utf8))
        try await session.close(handle)
    }

    @Test("a reply for an unsent request-id tears the session down")
    func unknownReplyIDIsAProtocolViolation() async throws {
        // The fake answers an OPEN by first sending, raw, an ATTRS
        // addressed to request-id 9999 — which nothing sent.
        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        fileSystem.createFile("/x", data: [1, 2, 3])
        server.interceptor = { message in
            if case .open = message.payload {
                var body: [UInt8] = [105]
                body.appendUInt32(9999)
                body.appendUInt32(0)
                return .replyRaw(body)
            }
            return .proceed
        }
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()
        do {
            _ = try await session.open(path: "/x", flags: .read)
            Issue.record("a bogus reply should end the session")
        } catch {
            guard case SFTPError.protocolViolation = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
        }
    }

    @Test("closing the session fails in-flight requests as cancelled")
    func closeFailsInFlight() async throws {
        let (session, server, fileSystem) = try await makePair { server in
            server.replyDelay = .milliseconds(500)
        }
        fileSystem.createFile("/big", data: [UInt8](repeating: 0x63, count: 64))
        let handle = try await session.open(path: "/big", flags: .read)

        let task = Task {
            try await session.read(handle: handle, offset: 0, length: 8)
        }
        #expect(server.waitFor("the read to arrive") { $0.readOffsets == [0] })
        session.close()
        do {
            _ = try await task.value
            Issue.record("a read on a closed session should throw")
        } catch {
            #expect(error as? SFTPError == .cancelled)
        }
    }

    @Test("a dropped connection fails in-flight requests as transport errors")
    func connectionDrop() async throws {
        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        fileSystem.createFile("/x", data: [1])
        server.interceptor = { message in
            if case .open = message.payload { return .dropConnection }
            return .proceed
        }
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()
        do {
            _ = try await session.open(path: "/x", flags: .read)
            Issue.record("the open should have failed with the connection")
        } catch {
            guard case SFTPError.transport = error else {
                Issue.record("expected a transport failure, got \(error)")
                return
            }
        }
    }
}
