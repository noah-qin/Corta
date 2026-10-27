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

import AppKit
import CortaSFTP
import Foundation
import Testing
@testable import Corta

extension SFTPBrowserModelTests {
    /// A selected folder downloads as a tree into `<chosen>/<name>` through
    /// the directory transfer; the row counts files, and what the walk
    /// skipped is surfaced rather than silent.
    @Test("a directory downloads as a tree and reports what was skipped")
    func directoryDownload() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("src", permissions: 0o040755, size: nil)]
        fake.onDirectoryTransfer = { _, progress in
            progress?(.init(filesCompleted: 1, filesTotal: 3, completedBytes: 10, totalBytes: 30))
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        #expect(model.canDownloadSelection == false)
        model.selection = ["src"]
        #expect(model.canDownloadSelection, "a directory is downloadable now")
        model.pickDownloadDestination = { _ in .directory(directory) }
        model.requestDownload()

        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
        let call = try #require(fake.directoryCalls.first)
        #expect(!call.isUpload)
        #expect(call.remotePath == "/srv/app/src")
        #expect(call.localPath == directory.appendingPathComponent("src").path)
        #expect(call.policy == "fail", "no destination → no question → per-file .fail")
        #expect(fake.transferCalls.isEmpty, "the tree goes through the directory transfer, not file by file here")
        let row = try #require(model.transfers.first)
        #expect(row.isDirectory)
        #expect(row.filesTotal == 2, "the fake's receipt: two files")
        #expect(row.state == .done(bytes: 300))
    }

    /// A folder chosen in the upload panel is a directory upload to
    /// `<current>/<name>`; an existing remote folder of that name asks
    /// first, and Overwrite becomes the per-file policy inside.
    @Test("uploading a folder onto an existing remote folder asks, and Overwrite applies per file")
    func directoryUploadConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("proj", permissions: 0o040755, size: nil)]
        fake.lstatResults["/srv/app/proj"] = SFTPAttributes(permissions: 0o040755)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickUploadFiles = { [source] }
        model.requestUpload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.path == "/srv/app/proj")
        #expect(fake.directoryCalls.isEmpty, "nothing moves before the answer")
        model.resolveConflict(prompt.id, choice: .overwrite)
        await waitUntil("done") {
            if case .done = model.transfers.first?.state { return true } else { return false }
        }
        let call = try #require(fake.directoryCalls.first)
        #expect(call.isUpload && call.remotePath == "/srv/app/proj" && call.policy == "overwrite")
        #expect(call.localPath == source.path)
    }

    @Test("an existing destination raises the conflict sheet; each choice maps to its policy")
    func downloadConflictChoices() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("a.txt")
        try "already here".write(to: existing, atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(existing) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.path == existing.path)
        #expect(!prompt.partialOnly)
        #expect(!prompt.canResume)
        // Both ends are described for the sheet; the wording itself is
        // locale-formatted, so the check stops at non-emptiness.
        #expect(!prompt.destinationDescription.isEmpty)
        #expect(!prompt.sourceDescription.isEmpty)

        // Skip: the row records the decision, nothing is sent.
        model.resolveConflict(prompt.id, choice: .skip)
        #expect(model.transfers.first?.state == .skipped)
        #expect(fake.transferCalls.isEmpty)

        // Overwrite maps to the engine's policy.
        model.requestDownload()
        await waitUntil("second conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(try #require(model.conflictPrompts.first).id, choice: .overwrite)
        await waitUntil("overwrite ran") { !fake.transferCalls.isEmpty }
        #expect(fake.transferCalls.last?.policy == "overwrite")
        #expect(fake.transferCalls.last?.localPath == existing.path)

        // Keep both: a renamed destination, still under .fail.
        model.requestDownload()
        await waitUntil("third conflict") { !model.conflictPrompts.isEmpty }
        model.resolveConflict(try #require(model.conflictPrompts.first).id, choice: .keepBoth)
        await waitUntil("keep-both ran") { fake.transferCalls.count >= 2 }
        let kept = try #require(fake.transferCalls.last)
        #expect(kept.localPath == directory.appendingPathComponent("a 2.txt").path)
        #expect(kept.policy == "fail")
    }

    @Test("a partial alone raises the partial wording and offers resume")
    func downloadPartialConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("a.txt")
        try "partial".write(
            to: URL(fileURLWithPath: SFTPTransferEngine.partialPath(for: destination.path)),
            atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.partialOnly)
        #expect(prompt.canResume)

        model.resolveConflict(prompt.id, choice: .resume)
        await waitUntil("resume ran") { !fake.transferCalls.isEmpty }
        let call = try #require(fake.transferCalls.last)
        #expect(call.policy == "resume")
        // A resumed run keeps its partial on interruption — the visible
        // `.corta-part` file, never a silent one at the destination name.
        #expect(call.disposition == .keepForResume)
    }

    @Test("an upload conflict is detected through the remote listing")
    func uploadConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("up.txt")
        try "outgoing".write(to: source, atomically: true, encoding: .utf8)

        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        // The remote destination already exists.
        fake.lstatResults["/srv/app/up.txt"] = SFTPAttributes(size: 42, permissions: 0o100644)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickUploadFiles = { [source] }
        model.requestUpload()

        await waitUntil("conflict sheet") { !model.conflictPrompts.isEmpty }
        let prompt = try #require(model.conflictPrompts.first)
        #expect(prompt.path == "/srv/app/up.txt")
        model.resolveConflict(prompt.id, choice: .overwrite)
        await waitUntil("upload ran") { !fake.transferCalls.isEmpty }
        let call = try #require(fake.transferCalls.first)
        #expect(call.isUpload)
        #expect(call.remotePath == "/srv/app/up.txt")
        #expect(call.policy == "overwrite")
    }

    @Test("cancel stops a running transfer and the row says so")
    func cancelTransfer() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("big.bin", size: 1_000_000)]
        fake.onTransfer = { _, progress in
            progress?(.init(completedBytes: 100, totalBytes: 1_000_000))
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(10)) }
            throw SFTPError.cancelled
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("big.bin")) }
        model.selection = ["big.bin"]
        model.requestDownload()

        await waitUntil("active") {
            guard case .active = model.transfers.first?.state else { return false }
            return true
        }
        let id = try #require(model.transfers.first?.id)
        model.cancelTransfer(id)
        await waitUntil("cancelled") {
            guard case .cancelled = model.transfers.first?.state else { return false }
            return true
        }
        // A .fail-policy run keeps nothing: no resumable partial is claimed.
        #expect(model.transfers.first?.state == .cancelled(partialKept: false))
    }
}

extension SFTPBrowserModelTests {
    @Test("a transport failure is retryable; retry re-runs under the same policy")
    func retryTransportFailure() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        var attempts = 0
        fake.onTransfer = { _, _ in
            attempts += 1
            if attempts == 1 { throw SFTPError.transport(.connectionLost) }
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("a.txt")) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("failed") {
            guard case .failed = model.transfers.first?.state else { return false }
            return true
        }
        guard case .failed(let message, let retryable) = model.transfers.first?.state else {
            Issue.record("expected a failed transfer")
            return
        }
        #expect(retryable, "transport-class failures offer Retry")
        #expect(message == L10n.format("sftp.error.connectionLost", "build-box"))

        let id = try #require(model.transfers.first?.id)
        model.retryTransfer(id)
        await waitUntil("retried to done") {
            guard case .done = model.transfers.first?.state else { return false }
            return true
        }
        #expect(attempts == 2)
        #expect(fake.transferCalls.count == 2)
        #expect(fake.transferCalls.last?.policy == "fail", "the same policy it ran with")
    }

    @Test("a server refusal is a definitive answer: failed, not retryable")
    func serverFailureIsNotRetryable() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        fake.onTransfer = { _, _ in
            throw SFTPError.server(SFTPStatus(code: .failure, message: Array("no".utf8)))
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.pickDownloadDestination = { _ in .file(directory.appendingPathComponent("a.txt")) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("failed") {
            guard case .failed = model.transfers.first?.state else { return false }
            return true
        }
        guard case .failed(_, let retryable) = model.transfers.first?.state else {
            Issue.record("expected a failed transfer")
            return
        }
        #expect(!retryable)
        let id = try #require(model.transfers.first?.id)
        model.retryTransfer(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.transferCalls.count == 1, "no retry for a definitive answer")
    }
}
