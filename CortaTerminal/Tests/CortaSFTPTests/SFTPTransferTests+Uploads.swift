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
                _ = release.wait(timeout: .now() + testTimeoutInterval(5))
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

    @Test("a cancelled upload retains only its acknowledged contiguous prefix")
    func cancelledUploadDiscardsSparseTail() async throws {
        let rig = try await makeRig(configureEngine: { $0.pipelineDepth = 1 })
        defer { teardown(rig) }
        let contents = (0..<2048).map { UInt8($0 % 229) }
        let source = try localFile(rig, "up", contents: contents, mtime: 7777)
        let partialPath = "/remote" + rig.partialName
        let wrote = Mutex(false)
        let prefix = Mutex(UInt64(0))
        let release = DispatchSemaphore(value: 0)
        let fileSystem = rig.fileSystem
        let transfer = Task {
            try await rig.engine.upload(
                from: source, to: "/remote", policy: .resume, partialDisposition: .keepForResume
            ) { update in
                prefix.withLock { $0 = update.completedBytes }
                // Model a later in-flight WRITE extending the file past a
                // missing block, without acknowledging that prefix.
                if let file = fileSystem.file(partialPath) {
                    fileSystem.createFile(
                        partialPath, data: file.data + Array(repeating: 0, count: 512),
                        modificationTime: 99_999)
                }
                wrote.withLock { $0 = true }
                _ = release.wait(timeout: .now() + testTimeoutInterval(5))
            }
        }
        #expect(try await waitForFlag(wrote))
        transfer.cancel()
        release.signal()
        await #expect(throws: SFTPError.cancelled) { try await transfer.value }
        let kept = try #require(fileSystem.file(partialPath))
        let confirmed = prefix.withLock { $0 }
        #expect(kept.data == Array(contents.prefix(Int(confirmed))))
        let fresh = SFTPTransferEngine(session: rig.session, configuration: rig.engine.configuration)
        let receipt = try await fresh.upload(from: source, to: "/remote", policy: .resume)
        #expect(receipt.resumedFromOffset == confirmed)
        #expect(fileSystem.file("/remote")?.data == contents)
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
}
