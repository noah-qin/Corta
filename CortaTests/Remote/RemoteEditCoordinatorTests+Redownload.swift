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

extension RemoteEditCoordinatorTests {
    /// The fixture, one conflict in: the local copy edited, the remote moved.
    private func stageConflict(
        _ fixture: Fixture, edit: String = "local edit"
    ) async throws -> RemoteEditCoordinator.UploadConflict {
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try edit.write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        fixture.fake.lstatResults["/srv/app/main.rs"] = SFTPAttributes(size: 999, modificationTime: 5000)
        fixture.coordinator.upload(pending)
        await waitUntil("conflict presented") { !fixture.coordinator.pendingConflicts.isEmpty }
        return try #require(fixture.coordinator.pendingConflicts.first)
    }

    /// The bug: the catch only showed the error, and the stale pending upload
    /// silenced every later save on that copy until the app quit.
    @Test("a re-download that fails asks the conflict again, and later saves still prompt")
    func failedRedownloadRestoresTheDecision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        let asked = fixture.recorder.conflicts.count
        fixture.fake.onTransfer = { call, _ in
            if !call.isUpload { throw SFTPError.server(SFTPStatus(code: .failure)) }
        }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("error said") { !fixture.recorder.errors.isEmpty }
        #expect(fixture.recorder.conflicts.count == asked + 1, "the decision is asked again")
        #expect(fixture.coordinator.pendingConflicts.map(\.id) == [conflict.id])
        #expect(!fixture.coordinator.uploadsInFlight.contains(conflict.id))
        #expect((try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "local edit")

        fixture.coordinator.resolveConflict(conflict.id, choice: .dismiss)
        let prompted = fixture.recorder.uploads.count
        try "a later save".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.recorder.uploads.count == prompted + 1, "a later save prompts")
    }

    /// Upload Anyway uploads the approved snapshot; the failed re-download
    /// must have left it, or that answer would do nothing and stick.
    @Test("after a failed re-download, Upload Anyway still works")
    func failedRedownloadKeepsTheSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        fixture.fake.onTransfer = { call, _ in
            if !call.isUpload { throw SFTPError.transport(.connectionLost) }
        }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("error said") { !fixture.recorder.errors.isEmpty }
        fixture.fake.onTransfer = { _, _ in }
        fixture.coordinator.resolveConflict(conflict.id, choice: .uploadAnyway)
        await waitUntil("uploaded") {
            fixture.fake.transferCalls.contains { $0.isUpload } && fixture.coordinator.pendingUploads.isEmpty
        }
        #expect(fixture.coordinator.uploadsInFlight.isEmpty)
    }

    @Test("while a re-download runs nothing else starts on the copy")
    func redownloadHoldsTheCopy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        let pending = try #require(fixture.coordinator.pendingUploads.first)
        let held = Guarded(wrappedValue: true)
        let started = Guarded(wrappedValue: false)
        fixture.fake.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            started.wrappedValue = true
            while held.wrappedValue { try await Task.sleep(for: .milliseconds(5)) }
            try "remote v2".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("download started") { started.wrappedValue }
        fixture.coordinator.resolveConflict(conflict.id, choice: .uploadAnyway)
        fixture.coordinator.resolveConflict(conflict.id, choice: .dismiss)
        fixture.coordinator.dismissUpload(pending)
        fixture.coordinator.upload(pending)
        #expect(!fixture.fake.transferCalls.contains { $0.isUpload })
        #expect(fixture.coordinator.pendingUploads.count == 1)
        held.wrappedValue = false
        await waitUntil("settled") { fixture.coordinator.uploadsInFlight.isEmpty }
        #expect((try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "remote v2")
        #expect(fixture.coordinator.pendingConflicts.isEmpty && fixture.coordinator.pendingUploads.isEmpty)
        #expect(!fixture.fake.transferCalls.contains { $0.isUpload })
    }

    /// The choice discarded the edits it was made about. A save after it is
    /// newer, and is not the download's to throw away.
    @Test("a save made during a re-download stands, and is a new edit to decide on")
    func aSaveDuringRedownloadWins() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        let prompted = fixture.recorder.uploads.count
        let held = Guarded(wrappedValue: true)
        let started = Guarded(wrappedValue: false)
        fixture.fake.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            started.wrappedValue = true
            while held.wrappedValue { try await Task.sleep(for: .milliseconds(5)) }
            try "remote v2".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("download started") { started.wrappedValue }
        try "saved meanwhile".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        held.wrappedValue = false
        await waitUntil("new edit prompted") { fixture.recorder.uploads.count == prompted + 1 }
        #expect((try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "saved meanwhile")
        #expect(fixture.recorder.errors.last == L10n.format("remoteEdit.redownloadSuperseded", "/srv/app/main.rs"))
        #expect(fixture.coordinator.pendingConflicts.isEmpty)
        #expect(fixture.coordinator.pendingUploads.first?.contentDigest
            == RemoteEditStore.sha256Hex(ofFile: fixture.localCopyURL))
        #expect(fixture.coordinator.uploadsInFlight.isEmpty)
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.store.approvalsURL.path))?
                .allSatisfy { !$0.hasSuffix(".corta-part") } != false)
    }

    /// Once the file is in place the copy is the remote version, whatever goes
    /// wrong next. Called a failed re-download, the conflict would come back
    /// with nothing left to decide, and a stale baseline behind it.
    @Test("failing to secure a re-download already in place says that, and keeps it")
    func securingAfterCommitIsDistinguished() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        let asked = fixture.recorder.conflicts.count
        fixture.fake.onTransfer = { call, _ in
            if !call.isUpload { try "remote v2".write(toFile: call.localPath, atomically: true, encoding: .utf8) }
        }
        fixture.coordinator.secureFile = { _ in throw CocoaError(.fileWriteNoPermission) }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("said") { !fixture.recorder.errors.isEmpty }
        #expect(fixture.recorder.errors.first
            == L10n.format("remoteEdit.redownloadUnsecured", "/srv/app/main.rs", "build-box"))
        #expect((try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "remote v2")
        #expect(fixture.recorder.conflicts.count == asked, "nothing left to decide")
        #expect(fixture.coordinator.pendingConflicts.isEmpty && fixture.coordinator.pendingUploads.isEmpty)
        #expect(fixture.store.copies[fixture.copyID]?.remoteMTime == 5000)
        #expect(fixture.store.copies[fixture.copyID]?.remoteDigest
            == RemoteEditStore.sha256Hex(ofFile: fixture.localCopyURL))
        // And it behaves as any baseline does.
        let prompted = fixture.recorder.uploads.count
        try "after".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        await fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.recorder.uploads.count == prompted + 1)
    }

    /// The other failures, before anything is in place: the copy is untouched.
    @Test("failing to prepare a re-download leaves the copy and asks again")
    func aFailedSwapLeavesTheCopy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let conflict = try await stageConflict(fixture)
        // The download "succeeds" and leaves nothing to put in place.
        fixture.fake.onTransfer = { _, _ in }
        fixture.coordinator.resolveConflict(conflict.id, choice: .redownload)
        await waitUntil("error said") { !fixture.recorder.errors.isEmpty }
        #expect((try? String(contentsOf: fixture.localCopyURL, encoding: .utf8)) == "local edit")
        #expect(fixture.coordinator.pendingConflicts.map(\.id) == [conflict.id])
    }

    /// Thirty seconds to type a password, or the connection was given up on
    /// with the dialog still up.
    @Test("a question on screen stops a remote edit's connection deadline")
    func theDeadlineWaitsForAnAnswer() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSFTPClient()
        fake.connectHangs = true
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: root), makeClient: { _ in fake },
            opener: { _, _, _ in true },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }),
            connectTimeout: .milliseconds(100))
        let asking = Guarded(wrappedValue: true)
        let asked = Guarded(wrappedValue: [String]())
        coordinator.isAskingHost = { host in
            asked.mutate { $0.append(host) }
            return asking.wrappedValue
        }
        let done = Guarded(wrappedValue: false)
        let open = Task { @MainActor in
            defer { done.wrappedValue = true }
            _ = try await coordinator.materialize(host: "deploy@box:2222", remotePath: "/f")
        }
        await waitUntil("the clock running") { !asked.wrappedValue.isEmpty }
        #expect(asked.wrappedValue.first == "deploy@box:2222")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!done.wrappedValue)
        #expect(!fake.closed)
        asking.wrappedValue = false
        await waitUntil("given up") { done.wrappedValue }
        #expect(fake.closed)
        await #expect(throws: (any Error).self) { try await open.value }
    }

    /// An operation's reconnect can ask for a password too.
    @Test("a question on screen stops a remote edit's operation deadline")
    func theOperationDeadlineWaitsForAnAnswer() async throws {
        let fixture = try makeFixture(operationTimeout: .milliseconds(100))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let asking = Guarded(wrappedValue: true)
        fixture.coordinator.isAskingHost = { _ in asking.wrappedValue }
        fixture.fake.lstatHangs = true
        let done = Guarded(wrappedValue: false)
        let operation = Task { @MainActor in
            defer { done.wrappedValue = true }
            _ = try await fixture.coordinator.materialize(host: "build-box", remotePath: "/srv/app/main.rs")
        }
        await waitUntil("asking the server") { fixture.fake.lstatsWaiting > 0 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!done.wrappedValue)
        #expect(!fixture.fake.closed)
        asking.wrappedValue = false
        await waitUntil("given up") { done.wrappedValue }
        #expect(fixture.fake.closed)
        await #expect(throws: (any Error).self) { try await operation.value }
    }
}
