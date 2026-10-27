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
}
