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

/// Remote editing — the store, the resolution, and the coordinator,
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
        let raw = try String(
            contentsOf: root.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(raw.contains("\"version\":1"))

        let reloaded = RemoteEditStore(rootURL: root)
        let loaded = try #require(reloaded.copy(host: "build-box", remotePath: "/srv/app/main.rs"))
        #expect(loaded.remoteSize == 1234)
        #expect(loaded.remoteMTime == 1_789_000_000)
        #expect(loaded.openCount == 1)
        #expect(loaded.localFile == copy.localFile)
    }

    @Test("a copy left alone past retention goes; an undecided edit and a recent copy stay")
    func retention() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let content = Data("SECRET=fake\n".utf8)
        let digest = RemoteEditStore.sha256Hex(content)
        let longAgo = Date(timeIntervalSinceNow: -RemoteEditStore.retention - 86_400)
        func stage(_ path: String, edited: Bool, modified: Date) throws -> RemoteEditStore.RemoteCopy {
            let copy = store.recordDownload(
                host: "build-box", remotePath: path, remoteSize: 12, remoteMTime: 1,
                remoteDigest: digest)
            let url = store.localURL(for: copy)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (edited ? Data("SECRET=edited\n".utf8) : content).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
            return copy
        }
        let stale = try stage("/srv/app/.env", edited: false, modified: longAgo)
        let undecided = try stage("/srv/app/config.yml", edited: true, modified: longAgo)
        let recent = try stage("/srv/app/notes.txt", edited: false, modified: Date())
        await store.finishMaintenance()
        await store.pruneStaleCopies()
        #expect(store.copies[stale.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: store.localURL(for: stale).path))
        #expect(store.copies[undecided.id] != nil)
        #expect(FileManager.default.fileExists(atPath: store.localURL(for: undecided).path))
        #expect(store.copies[recent.id] != nil)
        // The manifest on disk agrees.
        #expect(RemoteEditStore(rootURL: root).copies[stale.id] == nil)
    }

    @Test("maintenance does not hash an oversized file and a live edit is retained")
    func maintenanceBudgetAndLiveEdit() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        await store.finishMaintenance()
        let bytes = Data("unchanged".utf8)
        let copy = store.recordDownload(
            host: "box", remotePath: "/old",
            remoteSize: UInt64(bytes.count), remoteMTime: 1,
            remoteDigest: RemoteEditStore.sha256Hex(bytes))
        let url = store.localURL(for: copy)
        try store.secureCopy(at: url)
        try bytes.write(to: url)
        #expect(RemoteEditStore.sha256Hex(ofFile: url, byteLimit: 2) == nil)
        #expect(RemoteEditStore.sha256Hex(ofFile: url, byteLimit: bytes.count) == copy.remoteDigest)
        let old = Date(timeIntervalSinceNow: -RemoteEditStore.retention - 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        // An immutable maintenance snapshot cannot delete a copy opened since.
        store.recordOpen(copy)
        await store.pruneStaleCopies(candidates: [copy])
        #expect(store.copies[copy.id] != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
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
        let resolved = PaneRemote.resolve(Self.reference("src/main.rs"), state: Self.state)
        #expect(
            resolved
                == PaneRemote.ResolvedReference(
                    host: "build-box", remotePath: "/srv/app/src/main.rs",
                    line: 42, column: nil,
                    range: Self.reference("src/main.rs").range))
    }

    @Test("absolute paths pass through; dot segments are resolved")
    func absoluteAndDotSegments() {
        #expect(
            PaneRemote.resolve(Self.reference("/var/log/x.log"), state: Self.state)?
                .remotePath == "/var/log/x.log")
        #expect(
            PaneRemote.resolve(Self.reference("src/../Makefile"), state: Self.state)?
                .remotePath == "/srv/app/Makefile",
            "one remote file is one managed copy, however spelled")
    }

    @Test("a reported host that could not have been typed resolves nothing")
    func unacceptableHostIsRefused() {
        for host in ["evil`touch x`", "-oProxyCommand=x", "a b", "h\u{202E}x"] {
            let state = PaneRemoteState.remote(host: host, directory: "/srv", provenance: .osc7)
            #expect(PaneRemote.resolve(Self.reference("src/main.rs"), state: state) == nil, "\(host)")
        }
    }

    @Test("line and column ride along")
    func lineAndColumn() {
        let resolved = PaneRemote.resolve(
            Self.reference("a.rs", line: 7, column: 3), state: Self.state)
        #expect(resolved?.line == 7 && resolved?.column == 3)
    }

    @Test("what cannot be known honestly is refused")
    func refusals() {
        // "~" is the remote account's home — not knowable from here.
        #expect(PaneRemote.resolve(Self.reference("~/.bashrc"), state: Self.state) == nil)
        // No host, an uncertain pane, a local pane: nothing to resolve against.
        #expect(
            PaneRemote.resolve(
                Self.reference("a.rs"), state: .remoteUnknown(provenance: .foregroundProcess))
                == nil)
        #expect(PaneRemote.resolve(Self.reference("a.rs"), state: .unknown) == nil)
        #expect(PaneRemote.resolve(Self.reference("a.rs"), state: .local) == nil)
    }

    @Test("the managed copy's path and the reference's line reach the editor command")
    func editorArguments() {
        // The composition `open` performs: the local copy path is `{file}`,
        // the reference's line and column are substituted as themselves.
        let copyPath = "/tmp/store/build-box/0123abcd/main.rs"
        let arguments = PanePointer.openFileArguments(
            template: "/usr/bin/open -a editor --args {file} +{line}:{column}",
            path: copyPath, line: 42, column: 7)
        #expect(
            arguments == ["/usr/bin/open", "-a", "editor", "--args", copyPath, "+42:7"])
    }
}

@MainActor
struct RemoteEditCoordinatorTests {
    /// A presenter that records rather than alerts.
    final class Recorder {
        var uploads: [RemoteEditCoordinator.PendingUpload] = []
        var conflicts: [RemoteEditCoordinator.UploadConflict] = []
        var errors: [String] = []
        struct Opened {
            var url: URL
            var line: Int
            var column: Int?
        }
        var opened: [Opened] = []
    }

    /// A plain struct does not inherit the suite's MainActor isolation;
    /// the store it wraps is MainActor, so it must be.
    @MainActor
    struct Fixture {
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
    func makeFixture(
        remoteContent: String = "remote v1", operationTimeout: Duration = .seconds(120)
    ) throws -> Fixture {
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
                recorder.opened.append(.init(url: url, line: line, column: column))
                return true
            },
            presenter: RemoteEditCoordinator.RemoteEditPresenter(
                promptUpload: { recorder.uploads.append($0) },
                promptConflict: { recorder.conflicts.append($0) },
                showError: { recorder.errors.append($0) }),
            operationTimeout: operationTimeout)
        return Fixture(
            root: root, store: store, fake: fake, recorder: recorder, coordinator: coordinator)
    }

    @Test("remote copies never reach a default handler without a configured editor")
    func remoteDefaultHandlerRefused() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteEditStore(rootURL: root)
        let fake = FakeSFTPClient()
        var opened = 0
        let coordinator = RemoteEditCoordinator(
            store: store, makeClient: { _ in fake },
            opener: { url, line, column in
                opened += 1
                return PanePointer.openFileAt(
                    url: url, line: line, column: column,
                    allowsDefaultApplication: false, command: "")
            },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }))
        for name in ["evil.command", "evil.terminal", "evil.app", "script", "source.swift"] {
            let path = "/srv/" + name
            fake.lstatResults[path] = SFTPAttributes(size: 1)
            fake.onTransfer = { call, _ in
                try "echo SHOULD_NOT_RUN".write(toFile: call.localPath, atomically: true, encoding: .utf8)
            }
            #expect(try await !coordinator.open(host: "build-box", remotePath: path, line: 2, column: nil))
            #expect(try await !coordinator.open(host: "build-box", remotePath: path, line: 3, column: nil))
            #expect(store.copy(host: "build-box", remotePath: path)?.openCount == 0)
        }
        #expect(opened == 10)
        #expect(fake.transferCalls.count == 5, "cached copies pass the same guard")
    }

    @Test("an explicitly configured remote editor receives the file as data")
    func configuredRemoteEditorAllowed() {
        for name in ["file.swift", "evil.command", "semi;$(echo evil).terminal"] {
            #expect(PanePointer.openFileAt(
                url: URL(fileURLWithPath: "/tmp/" + name), line: 42, column: 7,
                allowsDefaultApplication: false, command: "/usr/bin/true {file} {line} {column}"))
        }
    }

    @Test("a failed stat retires a connection and the next action reconnects")
    func disconnectedClientIsReplaced() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FakeSFTPClient()
        let replacement = FakeSFTPClient()
        let path = "/srv/main.rs"
        first.lstatErrors[path] = .transport(.connectionLost)
        replacement.lstatResults[path] = SFTPAttributes(size: 2)
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
        await #expect(throws: SFTPError.transport(.connectionLost)) {
            try await coordinator.materialize(host: "build-box", remotePath: path)
        }
        #expect(first.closed)
        #expect(try await coordinator.open(host: "build-box", remotePath: path, line: 1, column: nil))
        #expect(made == 2 && !replacement.closed)
    }

    /// A client whose file at `path` is two bytes, downloaded as "ok".
    private static func client(serving path: String) -> FakeSFTPClient {
        let client = FakeSFTPClient()
        client.lstatResults[path] = SFTPAttributes(size: 2)
        client.onTransfer = { call, _ in
            try "ok".write(toFile: call.localPath, atomically: true, encoding: .utf8)
        }
        return client
    }

    /// How each of the silent-connection test's three opens ended.
    @MainActor private final class SilentConnectOutcomes {
        var aDone = false
        var bDone = false
        var cError: SFTPError?
    }

    /// A server whose SFTP subsystem never answered held every open of its
    /// host: cancelling one did not stop it waiting, and the next joined
    /// the same attempt. Each waiter now leaves on its own, the attempt
    /// ends with its last waiter or its deadline, and the next open
    /// connects afresh.
    @Test("a silent connection can be cancelled, times out, and the next open reconnects")
    func silentConnectionIsCancellableAndTimesOut() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/srv/main.rs"
        let firstSilent = FakeSFTPClient()
        let secondSilent = FakeSFTPClient()
        let working = Self.client(serving: path)
        for client in [firstSilent, secondSilent] { client.connectHangs = true }
        var made = 0
        let coordinator = RemoteEditCoordinator(
            store: RemoteEditStore(rootURL: root),
            makeClient: { _ in
                made += 1
                return [firstSilent, secondSilent, working][min(made, 3) - 1]
            },
            opener: { _, _, _ in true },
            presenter: .init(promptUpload: { _ in }, promptConflict: { _ in }, showError: { _ in }),
            // Long enough that the cancels below land first on a loaded
            // runner; the last waiter still meets it.
            connectTimeout: .seconds(3) * testTimeoutScale)

        let outcomes = SilentConnectOutcomes()

        // The only waiter cancels: it returns at once, and the attempt goes.
        let taskA = Task {
            defer { outcomes.aDone = true }
            _ = try await coordinator.materialize(host: "build-box", remotePath: path)
        }
        await waitUntil("first attempt started") { made == 1 }
        taskA.cancel()
        await waitUntil("cancelled open returned") { outcomes.aDone }
        #expect(firstSilent.closed)

        // Two waiters share the next attempt; one cancelling leaves it to
        // the other, which the deadline then releases.
        let taskB = Task {
            defer { outcomes.bDone = true }
            _ = try await coordinator.materialize(host: "build-box", remotePath: path)
        }
        let taskC = Task {
            do {
                _ = try await coordinator.materialize(host: "build-box", remotePath: path)
            } catch {
                outcomes.cError = error as? SFTPError
            }
        }
        await waitUntil("second attempt started") { made == 2 }
        taskB.cancel()
        await waitUntil("cancelled waiter returned") { outcomes.bDone }
        #expect(!secondSilent.closed, "the other waiter still wants this connection")
        await taskC.value
        if case .transport(.hostUnreachable)? = outcomes.cError {} else {
            Issue.record("expected the connect deadline, got \(String(describing: outcomes.cError))")
        }
        #expect(secondSilent.closed)

        // A fresh attempt, not the abandoned one.
        _ = try await coordinator.materialize(host: "build-box", remotePath: path)
        #expect(made == 3)
    }
}
