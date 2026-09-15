import AppKit
import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// B14, remote editing — the store, the resolution, and the coordinator,
/// all against the shared fake (`SFTPTestSupport.swift`) and per-test temp
/// directories. The real Application Support is never touched.
@MainActor
struct RemoteEditStoreTests {
    @Test("the local path is deterministic, per-host, and collision-safe")
    func deterministicNaming() {
        let first = RemoteEditStore.localRelativePath(host: "build-box", remotePath: "/srv/a/m.rs")
        let again = RemoteEditStore.localRelativePath(host: "build-box", remotePath: "/srv/a/m.rs")
        #expect(first == again, "the same remote file maps to the same copy")
        #expect(first.hasPrefix("build-box/"))
        #expect(first.hasSuffix("/m.rs"))
        let otherPath = RemoteEditStore.localRelativePath(host: "build-box", remotePath: "/srv/b/m.rs")
        let otherHost = RemoteEditStore.localRelativePath(host: "other", remotePath: "/srv/a/m.rs")
        #expect(first != otherPath && first != otherHost, "basename alone is not the key")
    }

    @Test("a hostile host name cannot escape the store root")
    func hostSanitizing() {
        // No separator survives, and a bare "." / ".." never does either —
        // the two ways a single path component escapes its directory.
        let name = RemoteEditStore.hostDirectoryName("evil/../../x")
        #expect(!name.contains("/"))
        #expect(RemoteEditStore.hostDirectoryName("..") == "_")
        #expect(RemoteEditStore.hostDirectoryName(".") == "_")
        #expect(RemoteEditStore.hostDirectoryName("") == "_")
        #expect(RemoteEditStore.hostDirectoryName("build-box.internal") == "build-box.internal")
    }

    @Test("the manifest round-trips with its version field")
    func manifestRoundTrip() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let copy = store.recordDownload(
            host: "build-box", remotePath: "/srv/app/main.rs",
            remoteSize: 1234, remoteMTime: 1_789_000_000)
        store.recordOpen(copy, at: Date(timeIntervalSince1970: 1_789_000_100))

        // The file itself carries the version (JSONEncoder is compact).
        let raw = try String(contentsOf: root.appendingPathComponent("manifest.json"))
        #expect(raw.contains("\"version\":1"))

        let reloaded = RemoteEditStore(rootURL: root)
        let loaded = try #require(reloaded.copy(host: "build-box", remotePath: "/srv/app/main.rs"))
        #expect(loaded.remoteSize == 1234)
        #expect(loaded.remoteMTime == 1_789_000_000)
        #expect(loaded.openCount == 1)
        #expect(loaded.localFile == copy.localFile)
    }

    @Test("a corrupt or future-version manifest degrades to empty, not to a guess")
    func manifestValidation() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try "not json at all".write(to: manifest, atomically: true, encoding: .utf8)
        #expect(RemoteEditStore(rootURL: root).copies.isEmpty)

        try #"{"version": 999, "copies": []}"#.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(RemoteEditStore(rootURL: root).copies.isEmpty)
    }
}

/// The pure resolution half: what a `path:line[:column]` in a remote pane
/// becomes, and what it never becomes.
struct RemoteReferenceResolutionTests {
    private static func reference(
        _ path: String, line: Int = 42, column: Int? = nil
    ) -> FileReferenceDetection.Reference {
        FileReferenceDetection.Reference(
            path: path, line: line, column: column,
            range: SelectionRange(
                start: SelectionPoint(row: 0, column: 0),
                end: SelectionPoint(row: 0, column: 1)))
    }

    private static let state = PaneRemoteState.remote(
        host: "build-box", directory: "/srv/app", provenance: .osc7)

    @Test("a relative reference joins the pane's remote directory")
    func relative() {
        let resolved = ViewController.resolveRemote(Self.reference("src/main.rs"), state: Self.state)
        #expect(
            resolved
                == ViewController.ResolvedRemoteReference(
                    host: "build-box", remotePath: "/srv/app/src/main.rs",
                    line: 42, column: nil,
                    range: Self.reference("src/main.rs").range))
    }

    @Test("absolute paths pass through; dot segments are resolved")
    func absoluteAndDotSegments() {
        #expect(
            ViewController.resolveRemote(Self.reference("/var/log/x.log"), state: Self.state)?
                .remotePath == "/var/log/x.log")
        #expect(
            ViewController.resolveRemote(Self.reference("src/../Makefile"), state: Self.state)?
                .remotePath == "/srv/app/Makefile",
            "one remote file is one managed copy, however spelled")
    }

    @Test("line and column ride along")
    func lineAndColumn() {
        let resolved = ViewController.resolveRemote(
            Self.reference("a.rs", line: 7, column: 3), state: Self.state)
        #expect(resolved?.line == 7 && resolved?.column == 3)
    }

    @Test("what cannot be known honestly is refused")
    func refusals() {
        // "~" is the remote account's home — not knowable from here.
        #expect(ViewController.resolveRemote(Self.reference("~/.bashrc"), state: Self.state) == nil)
        // No host, an uncertain pane, a local pane: nothing to resolve against.
        #expect(
            ViewController.resolveRemote(
                Self.reference("a.rs"), state: .remoteUnknown(provenance: .foregroundProcess))
                == nil)
        #expect(ViewController.resolveRemote(Self.reference("a.rs"), state: .unknown) == nil)
        #expect(ViewController.resolveRemote(Self.reference("a.rs"), state: .local) == nil)
    }

    @Test("the managed copy's path and the reference's line reach the editor command")
    func editorArguments() {
        // The composition `open` performs: the local copy path is `{file}`,
        // the reference's line and column are substituted as themselves.
        let copyPath = "/tmp/store/build-box/0123abcd/main.rs"
        let arguments = ViewController.openFileArguments(
            template: "/usr/bin/open -a editor --args {file} +{line}:{column}",
            path: copyPath, line: 42, column: 7)
        #expect(
            arguments == ["/usr/bin/open", "-a", "editor", "--args", copyPath, "+42:7"])
    }
}

@MainActor
struct RemoteEditCoordinatorTests {
    /// A presenter that records rather than alerts.
    private final class Recorder {
        var uploads: [RemoteEditCoordinator.PendingUpload] = []
        var conflicts: [RemoteEditCoordinator.UploadConflict] = []
        var errors: [String] = []
        var opened: [(url: URL, line: Int, column: Int?)] = []
    }

    /// A plain struct does not inherit the suite's MainActor isolation;
    /// the store it wraps is MainActor, so it must be.
    @MainActor
    private struct Fixture {
        var root: URL
        var store: RemoteEditStore
        var fake: FakeSFTPClient
        var recorder: Recorder
        var coordinator: RemoteEditCoordinator

        var copyID: String {
            RemoteEditStore.RemoteCopy.key(host: "build-box", remotePath: "/srv/app/main.rs")
        }

        var localCopyURL: URL {
            store.localURL(for: store.copies[copyID]!)
        }
    }

    /// A coordinator whose fake serves `/srv/app/main.rs` (size 100,
    /// mtime 1000); downloads write the canned content to the destination,
    /// the way the engine would.
    private func makeFixture(remoteContent: String = "remote v1") throws -> Fixture {
        let root = try makeTempDirectory()
        let store = RemoteEditStore(rootURL: root)
        let fake = FakeSFTPClient()
        fake.lstatResults["/srv/app/main.rs"] = SFTPAttributes(size: 100, modificationTime: 1000)
        let content = remoteContent
        fake.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            try content.write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        let recorder = Recorder()
        let coordinator = RemoteEditCoordinator(
            store: store,
            makeClient: { _ in fake },
            opener: { url, line, column in
                recorder.opened.append((url, line, column))
                return true
            },
            presenter: RemoteEditCoordinator.RemoteEditPresenter(
                promptUpload: { recorder.uploads.append($0) },
                promptConflict: { recorder.conflicts.append($0) },
                showError: { recorder.errors.append($0) }))
        return Fixture(
            root: root, store: store, fake: fake, recorder: recorder, coordinator: coordinator)
    }

    @Test("open downloads once, reuses the copy, and opens it at the reference's position")
    func openDownloadsAndReuses() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let opened = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 12, column: 3)
        #expect(opened)
        #expect(fixture.recorder.opened.count == 1)
        #expect(fixture.recorder.opened[0].line == 12 && fixture.recorder.opened[0].column == 3)
        #expect(fixture.recorder.opened[0].url.path.hasPrefix(fixture.root.path))

        // The manifest learned the remote stamp at download.
        let copy = try #require(fixture.store.copies[fixture.copyID])
        #expect(copy.remoteSize == 100 && copy.remoteMTime == 1000)
        #expect(copy.openCount == 1)
        #expect(fixture.fake.transferCalls.count == 1)
        #expect(fixture.fake.transferCalls[0].policy == "fail")
        #expect(fixture.fake.transferCalls[0].disposition == .remove)

        // Second open: the copy is reused, not downloaded again.
        let again = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        #expect(again)
        #expect(fixture.fake.transferCalls.count == 1, "no second download")
        #expect(fixture.store.copies[fixture.copyID]?.openCount == 2)
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
        let fake = FakeSFTPClient()
        let host = "consent-\(UUID().uuidString.prefix(8)).example"
        fake.lstatResults["/srv/app/main.rs"] = SFTPAttributes(size: 100, modificationTime: 1000)
        fake.onTransfer = { call, _ in
            guard !call.isUpload else { return }
            try "remote".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        final class Asked {
            var questions: [(host: String, path: String)] = []
            var answer = false
        }
        let asked = Asked()
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
        #expect(asked.questions[0].host == host && asked.questions[0].path == "/srv/app/main.rs")
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
        } catch let error as SFTPError {
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
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.isEmpty)
        #expect(fixture.recorder.uploads.isEmpty)

        // A real edit prompts, once.
        try "remote v1, edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.count == 1)
        #expect(fixture.recorder.uploads.count == 1)
        #expect(fixture.recorder.uploads[0].remoteDisplay == "build-box:/srv/app/main.rs")

        // A second edit while the first awaits a decision does not stack prompts.
        try "remote v1, edited more".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
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
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        // The upload succeeds; afterwards the server's stamp has moved.
        fixture.fake.onTransfer = { call, _ in
            if call.isUpload {
                fixture.fake.lstatResults["/srv/app/main.rs"] =
                    SFTPAttributes(size: 106, modificationTime: 2000)
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
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
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
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        #expect(fixture.coordinator.pendingUploads.isEmpty)
    }

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
            fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
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
        let elsewhere = fixture.root.appendingPathComponent("saved.rs")
        fixture.coordinator.resolveConflict(conflict.id, choice: .saveCopyElsewhere(elsewhere))
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
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        fixture.fake.lstatResults.removeValue(forKey: "/srv/app/main.rs")
        fixture.coordinator.upload(pending)
        await waitUntil("conflict presented") { !fixture.coordinator.pendingConflicts.isEmpty }
        let conflict = try #require(fixture.coordinator.pendingConflicts.first)
        #expect(conflict.remoteDeleted)
        #expect(conflict.remoteDescription == L10n.text("remoteEdit.conflict.deleted"))
    }

    @Test("a failed upload keeps the decision open and says the remote is untouched")
    func uploadFailureWording() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.coordinator.open(
            host: "build-box", remotePath: "/srv/app/main.rs", line: 1, column: nil)
        try "edited".write(to: fixture.localCopyURL, atomically: true, encoding: .utf8)
        fixture.coordinator.noteLocalWrite(copyID: fixture.copyID)
        let pending = try #require(fixture.coordinator.pendingUploads.first)

        fixture.fake.onTransfer = { call, _ in
            if call.isUpload { throw SFTPError.transport(.connectionLost) }
        }
        fixture.coordinator.upload(pending)
        await waitUntil("error presented") { !fixture.recorder.errors.isEmpty }
        let message = try #require(fixture.recorder.errors.first)
        #expect(
            message
                == L10n.format(
                    "remoteEdit.uploadFailed", "/srv/app/main.rs", "build-box",
                    SFTPBrowserModel.errorMessage(
                        .transport(.connectionLost), host: "build-box")))
        #expect(
            fixture.coordinator.pendingUploads.count == 1,
            "the decision is still owed — the upload can be asked for again")
    }
}
