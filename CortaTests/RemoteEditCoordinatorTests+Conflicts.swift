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
    @Test("upload anyway overwrites; save-elsewhere and dismiss send nothing")
    func conflictResolutions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        func stageConflict(_ content: String) async throws -> RemoteEditCoordinator.UploadConflict {
            _ = try await fixture.coordinator.open(
                host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
            // Fresh content each stage: the digest baseline moves with
            // every resolution, and an unchanged write prompts nothing.
            try content.write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
            await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
            let pending = try #require(fixture.coordinator.pendingUploads.first)
            fixture.fake.lstatResults["/srv/app/main.rs"] =
                SFTPAttributes(size: 999, modificationTime: 5000)
            fixture.coordinator.upload(pending)
            await waitUntil("conflict presented") {
                !fixture.coordinator.pendingConflicts.isEmpty
            }
            return fixture.coordinator.pendingConflicts.first!
        }

        // Upload anyway: the upload is sent despite the drift.
        var conflict = try await stageConflict("edit one")
        fixture.coordinator.resolveConflict(conflict.id, choice: .uploadAnyway)
        // The transfer call is recorded at the start of the fake's upload;
        // the manifest re-stamp is the flow's last step. Waiting for the
        // call alone lets the next stage's stamp reset lose the race
        // against the trailing re-stamp (full-suite load), silently
        // erasing the drift stage two needs to see.
        await waitUntil("uploaded anyway and re-stamped") {
            fixture.fake.transferCalls.contains { $0.isUpload }
                && fixture.store.copies[fixture.copyID]?.remoteMTime == 5000
        }
        #expect(fixture.fake.transferCalls.last?.policy == "overwrite")

        // Save elsewhere: both sides left alone, the copy written out.
        fixture.store.updateRemoteStamp(
            fixture.store.copies[fixture.copyID]!, size: 100, mtime: 1000)
        conflict = try await stageConflict("edit two")
        // A copy that cannot be written is said, and the decision asked again.
        let prompted = fixture.recorder.conflicts.count
        let errorsBefore = fixture.recorder.errors.count
        let unwritable = fixture.root.appendingPathComponent("missing/dir/saved.rs")
        fixture.coordinator.resolveConflict(conflict.id, choice: .saveCopyElsewhere(unwritable))
        await waitUntil("save failure reported") { fixture.recorder.errors.count == errorsBefore + 1 }
        #expect(fixture.recorder.errors.count == errorsBefore + 1)
        #expect(fixture.recorder.conflicts.count == prompted + 1)
        #expect(fixture.coordinator.pendingConflicts.count == 1)
        // A file the save panel agreed to replace is replaced.
        let elsewhere = fixture.root.appendingPathComponent("saved.rs")
        try "old".write(to: elsewhere, atomically: true, encoding: .utf8)
        fixture.coordinator.resolveConflict(conflict.id, choice: .saveCopyElsewhere(elsewhere))
        await waitUntil("saved elsewhere") { fixture.coordinator.pendingConflicts.isEmpty }
        #expect((try? String(contentsOf: elsewhere, encoding: .utf8)) == "edit two")
        #expect(fixture.coordinator.pendingConflicts.isEmpty)
        let uploadsBefore = fixture.fake.transferCalls.filter { $0.isUpload }.count

        // Dismiss: nothing happens, and nothing is sent.
        fixture.store.updateRemoteStamp(
            fixture.store.copies[fixture.copyID]!, size: 100, mtime: 1000)
        conflict = try await stageConflict("edit three")
        fixture.coordinator.resolveConflict(conflict.id, choice: .dismiss)
        #expect(fixture.coordinator.pendingUploads.isEmpty)
        #expect(
            fixture.fake.transferCalls.filter { $0.isUpload }.count == uploadsBefore,
            "dismiss sends nothing")
    }

    @Test("a deleted remote is its own conflict wording")
    func remoteDeletedConflict() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        fixture.fake.lstatResults.removeValue(forKey: "/srv/app/main.rs")
        fixture.coordinator.upload(pending)
        await waitUntil("conflict presented") { !fixture.coordinator.pendingConflicts.isEmpty }
        let conflict = try #require(fixture.coordinator.pendingConflicts.first)
        #expect(conflict.remoteDeleted)
        #expect(conflict.remoteDescription == L10n.text("remoteEdit.conflict.deleted"))
    }

    /// A lost connection may have cut the upload off anywhere, so the
    /// wording says the remote's state is not known rather than untouched.
    @Test("a failed upload keeps the decision open and says what is known of the remote")
    func uploadFailureWording() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        fixture.fake.onTransfer = { call, _ in
            if call.isUpload { throw SFTPError.transport(.connectionLost) }
            try "remote v1".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.upload(pending)
        await waitUntil("error presented") { !fixture.recorder.errors.isEmpty }
        let message = try #require(fixture.recorder.errors.first)
        #expect(
            message
                == L10n.format(
                    "remoteEdit.uploadUncertain", "/srv/app/main.rs", "build-box",
                    SFTPBrowserModel.errorMessage(
                        .transport(.connectionLost), host: "build-box")))
        #expect(
            fixture.coordinator.pendingUploads.count == 1,
            "the decision is still owed — the upload can be asked for again")
    }

    @Test("same-size same-timestamp remote replacement requires a conflict decision")
    func remoteContentReplacementIsDetected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        fixture.fake.onTransfer = { call, _ in
            if !call.isUpload { try "remote v2".write(toFile: call.localPath, atomically: true, encoding: .utf8) }
        }
        fixture.coordinator.upload(pending)
        await waitUntil("content conflict") { !fixture.coordinator.pendingConflicts.isEmpty }
        #expect(!fixture.fake.transferCalls.contains { $0.isUpload })
    }

    /// Remote editing shipped in 1.0.0, before digests were recorded: such a
    /// copy has only size and time, which miss a same-size rewrite within
    /// the second, so it takes the conflict decision docs/SECURITY.md
    /// promises instead of uploading over the remote unasked.
    @Test("a copy from before content digests asks for a conflict decision")
    func legacyCopyWithoutDigestAsksFirst() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        let copy = try #require(fixture.store.copies[fixture.copyID])
        fixture.store.updateRemoteStamp(copy, size: copy.remoteSize, mtime: copy.remoteMTime, digest: nil)
        #expect(fixture.store.copies[fixture.copyID]?.remoteDigest == nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        fixture.coordinator.upload(pending)
        await waitUntil("conflict") { !fixture.coordinator.pendingConflicts.isEmpty }
        #expect(!fixture.fake.transferCalls.contains { $0.isUpload })
        #expect(fixture.coordinator.pendingConflicts.first?.remoteDeleted == false)
    }

    /// The save panel's Replace is consent to replace the file with the
    /// copy. Removing it first and copying second lost it whenever the copy
    /// failed — here, a managed copy deleted while the conflict was shown.
    @Test("saving a copy elsewhere never removes the file it fails to replace")
    func saveElsewhereFailureKeepsExistingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("backup.rs")
        try "USER-BACKUP".write(to: existing, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try RemoteEditCoordinator.copyReplacing(
                root.appendingPathComponent("deleted.rs"), at: existing)
        }
        #expect((try? String(contentsOf: existing, encoding: .utf8)) == "USER-BACKUP")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == ["backup.rs"])

        let edit = root.appendingPathComponent("edit.rs")
        try "EDIT".write(to: edit, atomically: true, encoding: .utf8)
        try RemoteEditCoordinator.copyReplacing(edit, at: existing)
        #expect((try? String(contentsOf: existing, encoding: .utf8)) == "EDIT")
        // The same file as its own destination is already saved.
        try RemoteEditCoordinator.copyReplacing(existing, at: existing)
        #expect((try? String(contentsOf: existing, encoding: .utf8)) == "EDIT")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).sorted())
                == ["backup.rs", "edit.rs"])
    }

    @Test("approval snapshots a quit left behind are removed when the store opens")
    func staleApprovalSnapshotsAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-remote-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let approvals = root.appendingPathComponent("Approvals")
        try FileManager.default.createDirectory(at: approvals, withIntermediateDirectories: true)
        try Data("a whole copy of a remote file".utf8)
            .write(to: approvals.appendingPathComponent(UUID().uuidString))
        let store = RemoteEditStore(rootURL: root)
        #expect(store.approvalsURL.standardizedFileURL.path == approvals.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: approvals.path))
    }

    @Test("an edit after the prompt requires a fresh approval")
    func staleApprovalIsRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "first edit".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        try "second edit".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        fixture.coordinator.upload(pending)
        #expect(!fixture.fake.transferCalls.contains { $0.isUpload })
        await waitUntil("fresh approval offered") {
            fixture.coordinator.pendingUploads.first?.contentDigest
                == RemoteEditStore.sha256Hex(Data("second edit".utf8))
        }
    }
}

extension RemoteEditCoordinatorTests {
    @Test("an edit during preflight cannot replace the approved upload bytes")
    func uploadedBytesAreFrozen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "approved".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        var uploaded: String?
        fixture.fake.onTransfer = { call, _ in
            if call.isUpload {
                uploaded = try String(contentsOfFile: call.localPath, encoding: .utf8)
            } else {
                try "remote v1".write(toFile: call.localPath, atomically: true, encoding: .utf8)
                try "later edit".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
            }
        }
        fixture.coordinator.upload(pending)
        await waitUntil("frozen upload and subsequent edit checked") {
            uploaded != nil
                && fixture.coordinator.pendingUploads.first?.contentDigest
                    == RemoteEditStore.sha256Hex(Data("later edit".utf8))
        }
        #expect(uploaded == "approved")
        #expect(
            fixture.coordinator.pendingUploads.first?.contentDigest
                == RemoteEditStore.sha256Hex(Data("later edit".utf8)))
    }

    @Test("a silent established connection releases the upload and offers a fresh retry")
    func silentUploadTimesOut() async throws {
        let fixture = try makeFixture(operationTimeout: .seconds(1) * testTimeoutScale)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.recorder.uploads.first)
        let prompts = fixture.recorder.uploads.count
        fixture.fake.lstatHangs = true
        fixture.coordinator.upload(pending)
        await waitUntil("silent upload times out and asks again") {
            fixture.fake.closed && fixture.recorder.uploads.count > prompts
                && !fixture.coordinator.uploadsInFlight.contains(fixture.copyID)
        }
        #expect(!fixture.recorder.errors.isEmpty)
        #expect(fixture.coordinator.approvedSnapshots[fixture.copyID] == nil)
        fixture.fake.lstatHangs = false
        fixture.fake.closed = false
        fixture.coordinator.upload(try #require(fixture.recorder.uploads.last))
        await waitUntil("retry uploads the approved snapshot") {
            fixture.fake.transferCalls.contains { $0.isUpload }
                && !fixture.coordinator.uploadsInFlight.contains(fixture.copyID)
        }
    }

    /// A failed upload left the edit pending with no prompt: later saves
    /// were swallowed (it was already pending) and nothing offered a retry.
    @Test("a failed upload asks again")
    func failedUploadAsksAgain() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.recorder.uploads.first)
        let content = "remote v1"
        fixture.fake.onTransfer = { call, _ in
            if call.isUpload { throw SFTPError.transport(.connectionLost) }
            try content.write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.upload(pending)
        await waitUntil("the upload failed and was asked again") {
            !fixture.recorder.errors.isEmpty && fixture.recorder.uploads.count == 2
        }
        #expect(fixture.coordinator.pendingUploads.count == 1)
        // Answered again, the retry goes through.
        fixture.fake.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            try content.write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.upload(try #require(fixture.recorder.uploads.last))
        await waitUntil("the retry finished") { fixture.coordinator.pendingUploads.isEmpty }
    }

    /// The copy's content at a relaunch used to become the baseline, so an
    /// edit whose upload failed before the quit was never offered again.
    @Test("an edit never uploaded is pending when the copy is opened again")
    func unuploadedEditIsPendingOnReopen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited, never uploaded".write(
            to: fixture.localCopyURL, atomically: true, encoding: .utf8)

        // A fresh run: a new coordinator over the same store.
        let recorder = Recorder()
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: fixture.root), makeClient: { _ in fixture.fake },
            opener: { _, _, _ in true },
            presenter: .init(
                promptUpload: { recorder.uploads.append($0) },
                promptConflict: { recorder.conflicts.append($0) },
                showError: { recorder.errors.append($0) }))
        _ = try await coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        #expect(recorder.uploads.count == 1)
        #expect(fixture.fake.transferCalls.filter { !$0.isUpload }.count == 1, "the copy is reused")
    }

    /// Dismiss means "not this edit": it must not be offered again on every
    /// open after a relaunch.
    @Test("a dismissed edit is not offered again when the copy is reopened")
    func dismissedEditStaysDismissedAcrossARelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited, then dismissed".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        fixture.coordinator.dismissUpload(try #require(fixture.recorder.uploads.first))

        let recorder = Recorder()
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: fixture.root), makeClient: { _ in fixture.fake },
            opener: { _, _, _ in true },
            presenter: .init(
                promptUpload: { recorder.uploads.append($0) },
                promptConflict: { recorder.conflicts.append($0) },
                showError: { recorder.errors.append($0) }))
        _ = try await coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        #expect(recorder.uploads.isEmpty)
    }

    /// A copy the manifest no longer names may hold edits; the download used
    /// to refuse its path (policy `.fail`), and the file could not be opened.
    @Test("a copy missing from the manifest is kept aside, not overwritten")
    func orphanedCopyIsKeptAside() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relative = RemoteEditStore.localRelativePath(host: "build-box", remotePath: "/srv/app/main.rs")
        let orphan = fixture.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "local edits".write(to: orphan, atomically: true, encoding: .utf8)

        #expect(try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil))
        #expect(try String(contentsOf: orphan, encoding: .utf8) == "remote v1")
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: orphan.deletingLastPathComponent().path)
        let kept = try #require(siblings.first { $0.contains("(local copy ") })
        #expect(try String(
            contentsOf: orphan.deletingLastPathComponent().appendingPathComponent(kept),
            encoding: .utf8) == "local edits")
        #expect(fixture.recorder.errors.count == 1, "the user is told where it went")
    }

    @Test("a manifest from a newer Corta is not overwritten")
    func newerManifestIsPreserved() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        let newer = Data(#"{"version": 99, "copies": [], "future": true}"#.utf8)
        try newer.write(to: manifest)
        let store = RemoteEditStore(rootURL: root)
        #expect(store.preservesNewerManifest)
        store.recordDownload(host: "h", remotePath: "/p", remoteSize: 1, remoteMTime: 1)
        #expect(try Data(contentsOf: manifest) == newer)
    }

    @Test("managed copies and their manifest use owner-only modes")
    func managedCopyPermissions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        for url in [fixture.localCopyURL, fixture.root.appendingPathComponent("manifest.json")] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.root.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
    }
}
