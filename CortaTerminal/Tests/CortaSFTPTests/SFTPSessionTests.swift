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
import Testing

@testable import CortaSFTP

/// The session against the scripted fake server over the in-memory
/// loopback: handshake and capabilities, request/response plumbing, the
/// in-flight window bound, cancellation of in-flight requests, and
/// teardown on protocol violations.
@Suite("SFTP session", .serialized)
struct SFTPSessionTests {
    struct Pair {
        var session: SFTPSession
        var server: FakeSFTPServer
        var fileSystem: FakeRemoteFileSystem
    }

    /// Builds a connected session + server pair over a fresh loopback.
    func makePair(
        configure: (FakeSFTPServer) -> Void = { _ in }
    ) async throws -> Pair {
        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        configure(server)
        server.start()
        let session = SFTPSession(transport: connection.clientTransport())
        _ = try await session.connect()
        return Pair(session: session, server: server, fileSystem: fileSystem)
    }

    @Test("a silent VERSION wait is cancelled without an external close")
    func handshakeCancellation() async throws {
        let connection = SFTPLoopbackConnection()
        let session = SFTPSession(transport: connection.clientTransport())
        defer { session.close() }
        let task = Task { try await session.connect() }
        let deadline = SuspendingClock.now + .seconds(testTimeoutInterval(3))
        while !session.handshakePending, SuspendingClock.now < deadline {
            await Task.yield()
        }
        #expect(session.handshakePending)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled handshake succeeded")
        } catch { #expect(error as? SFTPError == .cancelled) }
        #expect(session.capabilities == nil)
    }

    @Test("a concurrent or repeated connect cannot steal the reader")
    func connectIsSingleUse() async throws {
        let connection = SFTPLoopbackConnection()
        let server = FakeSFTPServer(connection: connection, fileSystem: FakeRemoteFileSystem())
        let session = SFTPSession(transport: connection.clientTransport())
        defer { session.close() }
        let first = Task { try await session.connect() }
        let deadline = SuspendingClock.now + .seconds(testTimeoutInterval(3))
        while !session.handshakePending, SuspendingClock.now < deadline { await Task.yield() }
        #expect(session.handshakePending)
        await #expect(throws: SFTPError.protocolViolation("connect() called on a used session")) {
            try await session.connect()
        }
        server.start()
        #expect(try await first.value.version == 3)
        await #expect(throws: SFTPError.protocolViolation("connect() called on a used session")) {
            try await session.connect()
        }
        #expect(try await session.realPath(path: "/") == Array("/".utf8))
    }

    @Test("connect negotiates version 3 and reports advertised capabilities")
    func handshakeCapabilities() async throws {
        let pair = try await makePair { server in
            server.advertisedExtensions = [
                SFTPCodec.statVFSExtensionName, SFTPCodec.posixRenameExtensionName,
            ]
        }
        let session = pair.session
        defer { session.close() }
        let capabilities = try #require(session.capabilities)
        #expect(capabilities.version == 3)
        #expect(capabilities.supportsStatVFS)
        #expect(capabilities.supportsPosixRename)
    }

    @Test("a server without extensions reports both capabilities unavailable")
    func noCapabilitiesGuessed() async throws {
        let pair = try await makePair()
        let session = pair.session
        defer { session.close() }
        let capabilities = try #require(session.capabilities)
        #expect(!capabilities.supportsStatVFS)
        #expect(!capabilities.supportsPosixRename)
        // Degradation is explicit: volume info is unavailable, not zero.
        #expect(try await session.volumeInfo() == nil)
    }

    @Test("statvfs round-trips when the server speaks it")
    func statVFS() async throws {
        let pair = try await makePair { server in
            server.advertisedExtensions = [SFTPCodec.statVFSExtensionName]
        }
        let session = pair.session
        defer { session.close() }
        let info = try await #require(session.volumeInfo(path: "/"))
        #expect(info.blocks == 1000)
        #expect(info.blocksAvailable == 400)
        #expect(info.nameMaximum == 255)
    }

    @Test("an advertised-but-refused statvfs degrades to unavailable")
    func statVFSRefused() async throws {
        let pair = try await makePair { server in
            server.advertisedExtensions = [SFTPCodec.statVFSExtensionName]
            server.statVFSReply = nil
        }
        let session = pair.session
        defer { session.close() }
        #expect(try await session.volumeInfo() == nil)
    }

    @Test("open, write, read, close round-trip file contents")
    func fileRoundTrip() async throws {
        let pair = try await makePair()
        let session = pair.session, fileSystem = pair.fileSystem
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
        let pair = try await makePair()
        let session = pair.session, server = pair.server
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
        let pair = try await makePair()
        let session = pair.session, fileSystem = pair.fileSystem
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
        let pair = try await makePair { server in
            server.replyDelay = .milliseconds(50)
        }
        let session = pair.session, server = pair.server, fileSystem = pair.fileSystem
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
}

func blockThisThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

func waitBlocking(_ semaphore: DispatchSemaphore, seconds: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// Passes writes through until `stall()`, then blocks each until `release()`.
final class StallingTransport: SFTPChannelTransport, @unchecked Sendable {
    private let base: SFTPChannelTransport
    private let condition = NSCondition()
    private var stalled = false
    private var permits = 0

    init(_ base: SFTPChannelTransport) {
        self.base = base
    }

    func stall() {
        condition.lock()
        stalled = true
        condition.unlock()
    }

    func release() {
        condition.lock()
        stalled = false
        condition.broadcast()
        condition.unlock()
    }

    /// Lets `count` writes through while still stalled.
    func permit(_ count: Int) {
        condition.lock()
        permits += count
        condition.broadcast()
        condition.unlock()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws(SFTPTransportError) -> Int {
        try base.read(into: buffer)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError) {
        condition.lock()
        while stalled, permits == 0 { condition.wait() }
        if stalled { permits -= 1 }
        condition.unlock()
        try base.write(bytes)
    }

    func close() {
        release()
        base.close()
    }
}
