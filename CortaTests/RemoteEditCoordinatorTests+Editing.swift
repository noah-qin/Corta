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
import CortaTerminal
import Foundation
import Testing
@testable import Corta

extension RemoteEditCoordinatorTests {
    @Test("server errors preserve a connection; failed downloads retire it")
    func failedDownloadReconnectsButMissingFileDoesNot() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FakeSFTPClient()
        let replacement = FakeSFTPClient()
        let path = "/srv/main.rs"
        for client in [first, replacement] { client.lstatResults[path] = SFTPAttributes(size: 2) }
        first.onTransfer = { _, _ in throw SFTPError.transport(.connectionLost) }
        replacement.onTransfer = { call, _ in
            try "ok".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        var made = 0
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: root),
            makeClient: { _ in
                made += 1
                return made == 1 ? first : replacement
            },
            opener: { _, _, _ in true },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }))
        do {
            _ = try await coordinator.materialize(host: "build-box", remotePath: "/missing")
        } catch {
            #expect(error == .server(SFTPStatus(code: .noSuchFile)))
        }
        #expect(made == 1 && !first.closed)
        await #expect(throws: SFTPError.transport(.connectionLost)) {
            try await coordinator.materialize(host: "build-box", remotePath: path)
        }
        #expect(first.closed)
        #expect(try await coordinator.open(host: "build-box", remotePath: path, line: 1, column: nil))
        #expect(made == 2)
    }

    @Test("failed upload stays pending and reconnects only when retried")
    func failedUploadRetainsDecision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil))
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        fixture.fake.onTransfer = { call, _ in
            if call.isUpload { throw SFTPError.transport(.connectionLost) }
            try "remote v1".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.upload(pending)
        await waitUntil("failed upload reported") { !fixture.recorder.errors.isEmpty }
        #expect(fixture.fake.closed)
        #expect(fixture.coordinator.pendingUploads.count == 1)
        #expect(fixture.fake.transferCalls.filter(\.isUpload).count == 1)
    }

    @Test("an upload retry gets a fresh client without losing the pending edit")
    func uploadRetryReplacesClient() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let first = FakeSFTPClient()
        let second = FakeSFTPClient()
        let path = "/srv/main.rs"
        for client in [first, second] {
            client.lstatResults[path] = SFTPAttributes(size: 2, modificationTime: 1000)
        }
        first.onTransfer = { call, _ in
            if call.isUpload { throw SFTPError.transport(.connectionLost) }
            try "ok".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        second.onTransfer = { call, _ in
            if !call.isUpload { try "ok".write(toFile: call.localPath, atomically: true, encoding: .utf8) }
        }
        var made = 0
        var errors: [String] = []
        let coordinator = RemoteEditCoordinator(
            store: store,
            makeClient: { _ in
                made += 1
                return made == 1 ? first : second
            },
            opener: { _, _, _ in true },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { errors.append($0) }))
        #expect(try await coordinator.open(host: "build-box", remotePath: path, line: 1, column: nil))
        let copy = try #require(store.copy(host: "build-box", remotePath: path))
        try "edited".write(to: store.localURL(for: copy), atomically: true, encoding: .utf8)
        await coordinator.noteLocalWrite(copyID: copy.id)
        let pending = try #require(coordinator.pendingUploads.first)
        coordinator.upload(pending)
        await waitUntil("first upload failed") { !errors.isEmpty }
        #expect(first.closed && made == 1)
        #expect(coordinator.pendingUploads.count == 1)
        coordinator.upload(pending)
        await waitUntil("retry finished") { coordinator.pendingUploads.isEmpty }
        #expect(made == 2)
        #expect(second.transferCalls.filter(\.isUpload).count == 1)
        #expect(!second.closed)
    }

    @Test("an editor that saves immediately is still watched")
    func immediateEditorSaveIsDetected() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSFTPClient()
        let path = "/srv/main.rs"
        fake.lstatResults[path] = SFTPAttributes(size: 2)
        fake.onTransfer = { call, _ in
            try "original".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        let store = RemoteEditStore(rootURL: root)
        let coordinator = RemoteEditCoordinator(
            store: store, makeClient: { _ in fake },
            opener: { url, _, _ in
                do {
                    try "editor save".write(to: url, atomically: true, encoding: .utf8)
                    return true
                } catch {
                    Issue.record(error, "the stand-in editor could not save")
                    return false
                }
            },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }))
        // A reused copy after a coordinator restart has no in-memory digest.
        let relative = RemoteEditStore.localRelativePath(host: "build-box", remotePath: path)
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original".write(to: url, atomically: true, encoding: .utf8)
        _ = store.recordDownload(host: "build-box", remotePath: path, remoteSize: 2, remoteMTime: nil)
        #expect(try await coordinator.open(host: "build-box", remotePath: path, line: 1, column: nil))
        #expect(coordinator.pendingUploads.count == 1)
        #expect(fake.transferCalls.isEmpty)
    }

    @Test("open downloads once, reuses the copy, and opens it at the reference's position")
    func openDownloadsAndReuses() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let opened = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 12, column: 3)
        #expect(opened)
        #expect(fixture.recorder.opened.count == 1)
        let first = try #require(fixture.recorder.opened.first)
        #expect(first.line == 12 && first.column == 3)
        #expect(first.url.path.hasPrefix(fixture.root.path))

        // The manifest learned the remote stamp at download.
        let copy = try #require(fixture.store.copies[fixture.copyID])
        #expect(copy.remoteSize == 100 && copy.remoteMTime == 1000)
        #expect(copy.openCount == 1)
        #expect(fixture.fake.transferCalls.count == 1)
        let call = try #require(fixture.fake.transferCalls.first)
        #expect(call.policy == "fail")
        #expect(call.disposition == .remove)

        // Second open: the copy is reused, not downloaded again.
        let again = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        #expect(again)
        #expect(fixture.fake.transferCalls.count == 1, "no second download")
        #expect(fixture.store.copies[fixture.copyID]?.openCount == 2)
    }
}

extension RemoteEditCoordinatorTests {
    /// What the connection prompt was asked, and what it answers.
    private final class ConnectionQuestions {
        var questions: [(host: String, path: String)] = []
        var answer = false
    }

    /// A client whose file at `path` downloads as "remote".
    private static func downloadingClient(path: String) -> FakeSFTPClient {
        let client = FakeSFTPClient()
        client.lstatResults[path] = SFTPAttributes(size: 100, modificationTime: 1000)
        client.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            try "remote".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        return client
    }

    /// The first connection to a host is the user's decision, not the
    /// far end's: the host came from the pane's OSC 7 report — child
    /// output — so it is asked (host and path named) before any client is
    /// made, a refusal is `.cancelled` with nothing spawned, and an
    /// acceptance is remembered for the run (`RemoteHostConsent`).
    @Test("a first connection to a reported host is asked, and the answer is remembered")
    func firstConnectionIsAskedAndRemembered() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let fake = Self.downloadingClient(path: "/srv/app/main.rs")
        let host = "consent-\(UUID().uuidString.prefix(8)).example"
        let asked = ConnectionQuestions()
        var clientsMade = 0
        let coordinator = RemoteEditCoordinator(
            store: store,
            makeClient: { _ in
                clientsMade += 1
                return fake
            },
            opener: { _, _, _ in true },
            presenter: RemoteEditCoordinator.RemoteEditPresenter(
                promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in },
                confirmConnection: { host, path in
                    asked.questions.append((host, path))
                    return asked.answer
                }))

        // Declined: nothing is connected, nothing downloaded, and the
        // caller hears "cancelled" — the user's answer, not a failure.
        // (Spelled with a captured result rather than a typed `catch`:
        // the CI toolchain's SIL verifier crashed on that pattern.)
        var declined: SFTPError?
        do {
            _ = try await coordinator.open(
                host: host, remotePath: "/srv/app/main.rs", line: 1, column: nil)
        } catch {
            declined = error
        }
        #expect(declined == .cancelled, "expected .cancelled, got \(String(describing: declined))")
        #expect(asked.questions.count == 1)
        let question = try #require(asked.questions.first)
        #expect(question.host == host && question.path == "/srv/app/main.rs")
        #expect(clientsMade == 0)
        #expect(fake.transferCalls.isEmpty)
        #expect(!RemoteHostConsent.isConfirmed(host))

        // Accepted: connects, and the next open of the same host asks
        // nothing more.
        asked.answer = true
        #expect(
            try await coordinator.open(
                host: host, remotePath: "/srv/app/main.rs", line: 1, column: nil))
        #expect(asked.questions.count == 2)
        #expect(clientsMade == 1)
        #expect(RemoteHostConsent.isConfirmed(host))
        _ = try await coordinator.open(
            host: host, remotePath: "/srv/app/main.rs", line: 2, column: nil)
        #expect(asked.questions.count == 2, "a confirmed host is not asked again")
    }

    @Test("a missing remote file is the server's answer, surfaced typed")
    func openMissingRemoteFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            _ = try await fixture.coordinator.open(
                host: "build-box", remotePath: "/no/such/file.rs", line: 1, column: nil)
            Issue.record("expected a no-such-file failure")
        } catch {
            guard case .server(let status) = error, status.code == .noSuchFile else {
                Issue.record("expected .server(noSuchFile), got \(error)")
                return
            }
        }
        #expect(fixture.recorder.opened.isEmpty)
    }

    @Test("a local edit prompts; a write with unchanged content does not")
    func localChangeDetection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)

        // Same content: a touch, not an edit.
        try "remote v1".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.isEmpty)
        #expect(fixture.recorder.uploads.isEmpty)

        // A real edit prompts, once.
        try "remote v1, edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.count == 1)
        #expect(fixture.recorder.uploads.count == 1)
        #expect(fixture.recorder.uploads.first?.remoteDisplay == "build-box:/srv/app/main.rs")

        // A second edit while the first awaits a decision does not stack prompts.
        try "remote v1, edited more".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.count == 1)
    }

    @Test("the file watcher turns an editor's save into the prompt state")
    func watchIntegration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        // What an editor's atomic save looks like: new file, renamed over.
        try "edited by the editor".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await waitUntil("the watch fired and coalesced") {
            fixture.coordinator.pendingUploads.count == 1
        }
        #expect(fixture.recorder.uploads.count == 1)
    }

    @Test("an unchanged remote uploads; the manifest re-stamps")
    func uploadUnchangedRemote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        // The upload succeeds; afterwards the server's stamp has moved.
        fixture.fake.onTransfer = { call, _ in
            if call.isUpload {
                fixture.fake.lstatResults["/srv/app/main.rs"] =
                    SFTPAttributes(size: 106, modificationTime: 2000)
            } else {
                try "remote v1".write(toFile: call.localPath, atomically: true, encoding: .utf8)
            }
        }
        fixture.coordinator.upload(pending)
        await waitUntil("uploaded") { fixture.coordinator.pendingUploads.isEmpty }
        let upload = try #require(fixture.fake.transferCalls.first { $0.isUpload })
        #expect(upload.remotePath == "/srv/app/main.rs")
        #expect(upload.policy == "overwrite")
        #expect(upload.disposition == .remove, "an interrupted upload leaves no partial")
        let copy = try #require(fixture.store.copies[fixture.copyID])
        #expect(copy.remoteSize == 106 && copy.remoteMTime == 2000)
        #expect(fixture.coordinator.pendingConflicts.isEmpty)
    }

    @Test("a changed remote requires an explicit resolution")
    func remoteChangedConflict() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        // The remote moved since the download.
        fixture.fake.lstatResults["/srv/app/main.rs"] =
            SFTPAttributes(size: 999, modificationTime: 5000)
        fixture.coordinator.upload(pending)
        await waitUntil("conflict presented") { !fixture.coordinator.pendingConflicts.isEmpty }
        #expect(fixture.recorder.conflicts.count == 1)
        let conflict = try #require(fixture.coordinator.pendingConflicts.first)
        #expect(!conflict.remoteDeleted)
        #expect(!conflict.remoteDescription.isEmpty && !conflict.atDownloadDescription.isEmpty)
        #expect(fixture.fake.transferCalls.allSatisfy { !$0.isUpload }, "nothing sent yet")

        // Re-download discards the local edits and re-baselines.
        fixture.fake.onTransfer = { call, _ in
            if !call.isUpload {
                try "remote v2".write(toFile: call.localPath, atomically: true, encoding: .utf8)
            }
        }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        // Wait on the coordinator's *settled* state, not on the file's
        // content: the fake writes the destination inside the download
        // call, and the trailing bookkeeping (re-stamp, digest, pending
        // removal) happens after later resumptions on the same actor.
        // Waiting on the content observed the flow mid-flight, which is
        // exactly what full-suite load exploited.
        await waitUntil("re-downloaded and re-baselined") {
            fixture.store.copies[fixture.copyID]?.remoteMTime == 5000
                && fixture.coordinator.pendingUploads.isEmpty
        }
        #expect(fixture.coordinator.pendingConflicts.isEmpty)
        #expect(
            (try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "remote v2")
        // The local edits are gone, and the new content is the baseline:
        // checking the watch path now prompts nothing.
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.isEmpty)
    }
}
