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

        // The first upload is held at its first WRITE by the fake server,
        // on the server's own thread. Blocking in the client's progress
        // callback instead parked a cooperative-pool thread: under the
        // nightly sanitizers the pool starved, this test's own 200 ms sleep
        // could not run until the pause timed out, and both checks failed.
        let firstPaused = Mutex(false)
        let releaseFirst = DispatchSemaphore(value: 0)
        let pauseLimit = testTimeoutInterval(5)
        rig.server.interceptor = { message in
            guard case .write = message.payload,
                firstPaused.withLock({ paused in defer { paused = true }; return !paused })
            else { return .proceed }
            _ = releaseFirst.wait(timeout: .now() + pauseLimit)
            return .proceed
        }
        let firstTask = Task {
            try await rig.engine.upload(from: first, to: "/target", policy: .overwrite)
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
}
