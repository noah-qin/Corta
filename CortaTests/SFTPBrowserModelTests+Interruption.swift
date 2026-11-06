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

import CortaSFTP
import Foundation
import Testing
@testable import Corta

// MARK: - Reading and asking, and being able to stop

extension SFTPBrowserModelTests {
    /// A stuck stat, standing for a network volume whose server has gone.
    final class StuckDisk: Sendable {
        private let release = DispatchSemaphore(value: 0)
        let ranOnMain = Guarded(wrappedValue: [Bool]())

        var check: @Sendable () -> Void {
            { [self] in
                ranOnMain.mutate { $0.append(Thread.isMainThread) }
                _ = release.wait(timeout: .now() + 5)
            }
        }

        func letGo() { for _ in 0..<8 { release.signal() } }
    }

    private func hungQueue(_ disk: StuckDisk, timeout: DispatchTimeInterval = .milliseconds(50))
        -> SFTPLocalChecks {
        SFTPLocalChecks(timeout: timeout, budget: PathProbe.Budget(limit: 4), beforeCheck: disk.check)
    }

    @Test("a disk that does not answer fails that row, retryably, with the window free")
    func localCheckTimesOut() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        let disk = StuckDisk()
        defer { disk.letGo() }
        model.transferQueue.localChecks = hungQueue(disk)
        let destination = directory.appendingPathComponent("a.txt")
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["a.txt"]
        model.requestDownload()
        await waitUntil("failed") {
            if case .failed = model.transfers.first?.state { return true } else { return false }
        }
        let row = try #require(model.transfers.first)
        #expect(row.canRetry)
        #expect(row.state == .failed(
            message: L10n.format("sftp.transfer.localCheckTimedOut", destination.path), retryable: true))
        #expect(disk.ranOnMain.wrappedValue == [false], "never asked on the main thread")
        #expect(fake.transferCalls.isEmpty)

        // The disk is back: Retry asks again, from the question.
        disk.letGo()
        model.transferQueue.localChecks = SFTPLocalChecks()
        model.retryTransfer(row.id)
        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
    }

    @Test("an upload's source is read off the main thread, and its kind found there")
    func uploadSourceIsReadOffMain() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        let ranOnMain = Guarded(wrappedValue: [Bool]())
        model.transferQueue.localChecks = SFTPLocalChecks(beforeCheck: {
            ranOnMain.mutate { $0.append(Thread.isMainThread) }
        })
        #expect(model.upload([folder]))
        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
        #expect(ranOnMain.wrappedValue == [false])
        #expect(model.transfers.first?.isDirectory == true)
        #expect(fake.directoryCalls.first?.isUpload == true)
    }

    /// A thousand files dropped at once are a thousand questions, not a budget
    /// of a few spent in the first instant and the rest reported as failures.
    @Test("many rows at once all get their answer")
    func manyRowsTakeTurnsAtTheDisk() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.transferQueue.localChecks = SFTPLocalChecks(budget: PathProbe.Budget(limit: 1))
        let urls = try (0..<40).map { index -> URL in
            let url = directory.appendingPathComponent("f\(index)")
            try Data([1]).write(to: url)
            return url
        }
        #expect(model.upload(urls))
        await waitUntil("all done") {
            model.transfers.count == 40 && model.transfers.allSatisfy {
                if case .done = $0.state { return true } else { return false }
            }
        }
    }

    @Test("cancelling a row in pre-flight stops what it was asking the server")
    func cancelInPreflight() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("up.txt")
        try "outgoing".write(to: source, atomically: true, encoding: .utf8)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        fake.lstatHangs = true
        fake.lstatCancelled = false
        #expect(model.upload([source]))
        await waitUntil("asking") { fake.lstatsWaiting > 0 }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        #expect(model.transfers.first?.state == .cancelled(partialKept: false))
        await waitUntil("the request stopped") { fake.lstatCancelled }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.transferCalls.isEmpty, "never started")
    }

    @Test("cancelling a row during Keep Both's search stops the search")
    func cancelDuringKeepBoth() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("up.txt")
        try "outgoing".write(to: source, atomically: true, encoding: .utf8)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        fake.lstatResults["/srv/app/up.txt"] = SFTPAttributes(size: 42, permissions: 0o100644)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        #expect(model.upload([source]))
        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        fake.lstatHangs = true
        model.resolveConflict(prompt.id, choice: .keepBoth)
        await waitUntil("searching") { fake.lstatsWaiting > 0 }
        model.cancelTransfer(prompt.transferID)
        await waitUntil("the request stopped") { fake.lstatCancelled }
        #expect(model.transfers.first?.state == .cancelled(partialKept: false))
        #expect(fake.transferCalls.isEmpty)
    }

    /// The audit's reproduction: a transfer stuck where cancellation cannot
    /// reach it — a read from a volume that has gone — left the row saying
    /// Cancelling for good, with nothing further to press.
    @Test("a transfer that will not stop still lets its row settle")
    func cancellingConverges() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("big.bin", size: 1_000_000)]
        let stuck = Guarded(wrappedValue: true)
        fake.onTransfer = { _, _ in
            // Deaf to cancellation, as blocking I/O is.
            while stuck.wrappedValue { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let model = await connectedModel(fake: fake)
        defer {
            stuck.wrappedValue = false
            model.disconnect()
        }
        model.transferQueue.cancellingTimeout = .milliseconds(50)
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("big.bin")) }
        model.selection = ["big.bin"]
        model.requestDownload()
        await waitUntil("running") { !fake.transferCalls.isEmpty }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        #expect(model.transfers.first?.state == .cancelling)
        await waitUntil("settled") { model.transfers.first?.state == .cancelled(partialKept: false) }
    }

    @Test("a run given up on, and retried, does not speak for the new one")
    func aLateRunDoesNotOverwriteARetry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("big.bin")
        try "partial".write(
            to: URL(fileURLWithPath: SFTPTransferEngine.partialPath(for: partial.path)),
            atomically: true, encoding: .utf8)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("big.bin", size: 1_000_000)]
        let firstStuck = Guarded(wrappedValue: true)
        let secondStuck = Guarded(wrappedValue: true)
        let runs = Guarded(wrappedValue: 0)
        fake.onTransfer = { _, _ in
            let run = runs.mutate { count -> Int in
                count += 1
                return count
            }
            let gate = run == 1 ? firstStuck : secondStuck
            while gate.wrappedValue { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let model = await connectedModel(fake: fake)
        defer {
            firstStuck.wrappedValue = false
            secondStuck.wrappedValue = false
            model.disconnect()
        }
        model.transferQueue.cancellingTimeout = .milliseconds(20)
        model.pickDownloadDestination = { _ in .file(partial) }
        model.selection = ["big.bin"]
        model.requestDownload()
        await waitUntil("conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(try #require(model.conflictPrompts.first).id, choice: .resume)
        await waitUntil("running") { runs.wrappedValue == 1 }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        await waitUntil("settled, partial kept") { model.transfers.first?.state == .cancelled(partialKept: true) }
        model.retryTransfer(id)
        await waitUntil("second run") { runs.wrappedValue == 2 }
        // The first finishes after all; the row belongs to the second now.
        firstStuck.wrappedValue = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.transfers.first?.state == .queued)
        secondStuck.wrappedValue = false
        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
    }

    @Test("a cancelled run that kept its partial offers Retry, and continues it")
    func cancelledResumeRetries() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("big.bin")
        try "partial".write(
            to: URL(fileURLWithPath: SFTPTransferEngine.partialPath(for: destination.path)),
            atomically: true, encoding: .utf8)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("big.bin", size: 1_000_000)]
        let attempts = Guarded(wrappedValue: 0)
        fake.onTransfer = { _, _ in
            let attempt = attempts.mutate { count -> Int in
                count += 1
                return count
            }
            guard attempt == 1 else { return }
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw SFTPError.cancelled
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["big.bin"]
        model.requestDownload()
        await waitUntil("conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(try #require(model.conflictPrompts.first).id, choice: .resume)
        await waitUntil("running") { attempts.wrappedValue == 1 }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        await waitUntil("cancelled") { model.transfers.first?.state == .cancelled(partialKept: true) }
        #expect(model.transfers.first?.canRetry == true)
        model.retryTransfer(id)
        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
        #expect(fake.transferCalls.last?.policy == "resume")
    }

    @Test("a run that left no partial has nothing to retry")
    func cancelledWithoutPartialDoesNotRetry() {
        let row = { (state: SFTPTransferQueue.TransferState) in
            SFTPTransferQueue.Transfer(
                id: UUID(), isUpload: false, name: "a", localURL: URL(fileURLWithPath: "/tmp/a"),
                host: "h", state: state)
        }
        #expect(!row(.cancelled(partialKept: false)).canRetry)
        #expect(row(.cancelled(partialKept: true)).canRetry)
        #expect(row(.failed(message: "", retryable: true)).canRetry)
        #expect(!row(.failed(message: "", retryable: false)).canRetry)
        #expect(!row(.skipped).canRetry)
    }
}
