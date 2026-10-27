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
        let deadline = SuspendingClock.now + .seconds(testTimeoutInterval(15))
        while !progress.wasSeen, SuspendingClock.now < deadline {
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
        rig.server.waitFor("the close of the aborted handle") { $0.closeCount >= 1 }
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
        let deadline = SuspendingClock.now + .seconds(testTimeoutInterval(15))
        while !progress.wasSeen, SuspendingClock.now < deadline {
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
        rig.server.waitFor("the failed listing's close") { $0.closeCount >= 1 }
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
                _ = releaseSecond.wait(timeout: .now() + testTimeoutInterval(5))
            }
            let first = Task {
                try await rig.engine.download(
                    remotePath: "/file", to: rig.directory.appendingPathComponent("first")) { _ in
                    firstAtProgress.withLock { $0 = true }
                    _ = releaseFirst.wait(timeout: .now() + testTimeoutInterval(5))
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
            await expectOutcome(of: second, cancelled: cancelBeforeRegistration)
            if cancelBeforeRegistration {
                releaseFirst.signal()
                _ = try await first.value
            }
        }
    }

    /// A transfer cancelled before it finished throws `.cancelled`; any
    /// other completes.
    func expectOutcome<Value>(
        of transfer: Task<Value, any Error>, cancelled: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await transfer.value
            #expect(!cancelled, sourceLocation: sourceLocation)
        } catch {
            #expect(cancelled, sourceLocation: sourceLocation)
            #expect(error as? SFTPError == .cancelled, sourceLocation: sourceLocation)
        }
    }

    /// Polls `flag` until it is set or `deadline` (three seconds from now by
    /// default) passes; its final value.
    func waitForFlag(
        _ flag: borrowing Mutex<Bool>,
        until deadline: SuspendingClock.Instant = .now + .seconds(testTimeoutInterval(3))
    ) async throws -> Bool {
        while !flag.withLock({ $0 }), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return flag.withLock { $0 }
    }
}
