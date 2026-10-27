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

extension SFTPSessionTests {
    @Test("cancelling an in-flight request resumes it cancelled and the session survives")
    func requestCancellation() async throws {
        let pair = try await makePair { server in
            server.replyDelay = .milliseconds(500)
        }
        let session = pair.session, server = pair.server, fileSystem = pair.fileSystem
        defer { session.close() }
        fileSystem.createFile("/big", data: [UInt8](repeating: 0x62, count: 64))
        let handle = try await session.open(path: "/big", flags: .read)

        let task = Task {
            try await session.read(handle: handle, offset: 0, length: 8)
        }
        // Let the request reach the server, then cancel.
        server.waitFor("the read to arrive") { $0.readOffsets == [0] }
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

    @Test("withheld cancelled replies exhaust a bounded budget and a fresh session recovers")
    func cancelledReplyBudget() async throws {
        let connection = SFTPLoopbackConnection()
        let server = FakeSFTPServer(connection: connection, fileSystem: FakeRemoteFileSystem())
        server.interceptor = { message in
            if case .read = message.payload { return .ignore }
            return .proceed
        }
        server.start()
        var configuration = SFTPSession.Configuration()
        configuration.maxCancelledRequests = 4
        let session = SFTPSession(transport: connection.clientTransport(), configuration: configuration)
        defer { session.close() }
        _ = try await session.connect()
        let handle = SFTPHandle(rawValue: [1])
        for offset in 0..<4 {
            let task = Task { try await session.read(handle: handle, offset: UInt64(offset), length: 1) }
            server.waitFor("read on wire") { $0.readOffsets.count == offset + 1 }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled read succeeded")
            } catch { #expect(error as? SFTPError == .cancelled) }
            #expect(session.retainedLateReplyCount <= configuration.maxCancelledRequests)
        }
        await #expect(throws: SFTPError.protocolViolation("too many cancelled requests awaiting replies")) {
            try await session.realPath(path: "/")
        }
        #expect(session.retainedLateReplyCount == 0, "terminal cleanup releases the ledger")
        let pair = try await makePair()
        let fresh = pair.session
        defer { fresh.close() }
        #expect(try await fresh.realPath(path: "/") == Array("/".utf8))
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
        let pair = try await makePair { server in
            server.replyDelay = .milliseconds(500)
        }
        let session = pair.session, server = pair.server, fileSystem = pair.fileSystem
        fileSystem.createFile("/big", data: [UInt8](repeating: 0x63, count: 64))
        let handle = try await session.open(path: "/big", flags: .read)

        let task = Task {
            try await session.read(handle: handle, offset: 0, length: 8)
        }
        server.waitFor("the read to arrive") { $0.readOffsets == [0] }
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

    @Test("senders blocked on a full channel park no cooperative thread")
    func blockedWritesLeaveTheCooperativePoolFree() async throws {
        let connection = SFTPLoopbackConnection()
        let fileSystem = FakeRemoteFileSystem()
        let server = FakeSFTPServer(connection: connection, fileSystem: fileSystem)
        server.start()
        let transport = StallingTransport(connection.clientTransport())
        let session = SFTPSession(transport: transport)
        _ = try await session.connect()
        defer {
            transport.release()
            session.close()
            connection.close()
        }

        // Every write from here blocks, like ssh behind a slow network.
        // More senders than the pool has threads: if each held one while
        // blocked, nothing else in the process could run.
        transport.stall()
        let senders = ProcessInfo.processInfo.activeProcessorCount + 2
        for index in 0..<senders {
            Task.detached { _ = try? await session.stat(path: "/\(index)") }
        }
        // Blocking, not `Task.sleep`: a starved pool would never resume us.
        blockThisThread(seconds: 0.3)

        let probe = DispatchSemaphore(value: 0)
        Task.detached { probe.signal() }
        #expect(
            waitBlocking(probe, seconds: testTimeoutInterval(5)),
            "an unrelated task could not run while SFTP writes were blocked")
    }
}

extension SFTPSessionTests {
    @Test("cancelled requests cannot grow the writer queue past the window")
    func cancellationKeepsTheWriterQueueBounded() async throws {
        let connection = SFTPLoopbackConnection()
        let server = FakeSFTPServer(connection: connection, fileSystem: FakeRemoteFileSystem())
        server.start()
        let transport = StallingTransport(connection.clientTransport())
        let session = SFTPSession(transport: transport)
        _ = try await session.connect()
        defer {
            transport.release()
            session.close()
            connection.close()
        }

        transport.stall()
        // Each request gives its slot back the moment it is cancelled, while
        // its frame stays queued behind the stalled write.
        for round in 0..<200 {
            let task = Task.detached { _ = try? await session.stat(path: "/\(round)") }
            blockThisThread(seconds: 0.002)
            task.cancel()
        }
        blockThisThread(seconds: 0.3)
        #expect(session.unwrittenFrameCount <= session.configuration.maxInFlightRequests)

        // Senders waiting behind the full queue; then one write completes.
        for round in 0..<40 {
            Task.detached { _ = try? await session.stat(path: "/waiting/\(round)") }
        }
        blockThisThread(seconds: 0.2)
        transport.permit(1)
        blockThisThread(seconds: 0.3)
        // One place freed admits one sender, not every waiter at once.
        #expect(session.unwrittenFrameCount <= session.configuration.maxInFlightRequests)
    }
}
