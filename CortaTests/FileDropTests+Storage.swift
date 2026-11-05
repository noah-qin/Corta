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
import CortaPOSIX
import CortaSFTP
import CortaTerminal
import Testing

@testable import Corta

extension FileDropTests {
    @Test("private drop storage clears inherited ACLs, tightens modes and refuses symlinks")
    func privatePermissions() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o777])
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read,file_inherit,directory_inherit", root.path]
        try command.run()
        command.waitUntilExit()
        try #require(command.terminationStatus == 0)
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("private")
        try Data("secret".utf8).write(to: file)
        try FileDropStorage.secureReceived(file, in: directory)
        for (url, mode) in [(root, 0o700), (directory, 0o700), (file, 0o600)] {
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == mode)
            if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                #expect(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0)
            } else { #expect(errno == ENOENT) }
        }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try FileDropStorage.secureReceived(link, in: directory) }
        #expect(throws: (any Error).self) {
            try FileDropStorage.secureReceived(root.appendingPathComponent("outside"), in: directory)
        }
    }

    @Test("a hard link to a file elsewhere is refused and the original keeps its mode")
    func hardLinkLeavesOriginalAlone() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let original = root.appendingPathComponent("original")
        try Data("mine".utf8).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.linkItem(at: original, to: link)
        #expect(throws: (any Error).self) { try FileDropStorage.secureReceived(link, in: directory) }
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? Int == 0o644)
    }

    @Test("removal leaves the path at once and finishes off the caller's thread")
    func removalIsImmediateAtThePath() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("file"))
        FileDropStorage.remove(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await waitUntil("the renamed folder was deleted") {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? ["left"]).isEmpty
        }
        FileDropStorage.remove(folder)
    }

    @Test("a late promised file is removed alone once its neighbours were handed out")
    func lateCopyRemovedAlone() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let ready = directory.appendingPathComponent("ready")
        let late = directory.appendingPathComponent("late")
        let original = root.appendingPathComponent("original")
        for file in [ready, late, original] { try Data().write(to: file) }
        let collection = FileDropCollection(count: 2, directory: directory)
        collection.record(ready, index: 0, owned: true)
        _ = collection.finish(timedOut: true)
        collection.record(original, index: 1)
        collection.record(late, index: 1, owned: true)
        #expect(!FileManager.default.fileExists(atPath: late.path))
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("a plain URL that succeeds alongside failed promises does not keep their directory")
    func mixedDropDropsUnusedDirectory() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let collection = FileDropCollection(count: 2, directory: directory)
        collection.record(URL(fileURLWithPath: "/tmp/original"), index: 0)
        collection.record(nil, index: 1)
        let result = collection.finish(timedOut: false)
        #expect(result.urls.map(\.path) == ["/tmp/original"])
        #expect(result.directory == nil)
        #expect(result.failed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a reception's notice survives an empty result and the reload after its upload")
    func receptionNotices() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let model = await connectedModel(fake: FakeSFTPClient())
        defer { model.disconnect(); model.removeReceivedDrops() }
        let generation = model.connectionGeneration
        model.finishReception(.init(urls: [], directory: nil, failed: true, timedOut: true),
            into: "/", generation: generation)
        #expect(model.listingError == L10n.text("drop.timeout"))
        model.finishReception(.init(urls: [], directory: nil, failed: true, timedOut: false),
            into: "/", generation: generation + 1)
        #expect(model.listingError == L10n.text("drop.connectionChanged"))
        let file = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: file)
        model.finishReception(.init(urls: [file], directory: nil, failed: true, timedOut: false),
            into: "/", generation: generation)
        await waitUntil("the upload finished") {
            if case .done = model.transfers.first?.state { return true }
            return false
        }
        await waitUntil("the reload settled") { !model.isLoading }
        #expect(model.listingError == nil)
        #expect(model.receptionNotice == L10n.text("drop.partial"))
        // An unrelated upload cannot bring it back once it has gone.
        model.removeReceivedDrops()
        #expect(model.receptionNotice == nil)
        #expect(model.upload([file]))
        await waitUntil("the second upload finished") {
            model.transfers.count == 2 && model.transfers.allSatisfy {
                if case .done = $0.state { return true }
                return false
            }
        }
        await waitUntil("the second reload settled") { !model.isLoading }
        #expect(model.receptionNotice == nil)
    }

    @Test("a stage with a symlinked parent receives into a canonical private directory")
    func stagedParentAlias() throws {
        let fixture = scratchRoot()
        defer { FileDropStorage.remove(fixture) }
        let real = fixture.appendingPathComponent("real")
        let alias = fixture.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let directory = try FileDropStorage.makeDirectory(in: alias.appendingPathComponent("drops"))
        let file = FileDropStorage.destination(in: directory).appendingPathComponent("file")
        try Data().write(to: file)
        try FileDropStorage.secureReceived(file, in: FileDropStorage.destination(in: directory))
        #expect(directory.path == directory.resolvingSymlinksInPath().path)
    }

    /// A pid no process holds: above the kernel's limit.
    private static let deadPID = 99_999_999

    @Test("startup removes a dead owner's receptions and nothing else")
    func staleCleanup() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let uuid = UUID().uuidString
        let dead = root.appendingPathComponent("\(Self.deadPID)-\(uuid)")
        let live = root.appendingPathComponent("\(getpid())-\(uuid)")
        let foreign = root.appendingPathComponent("not-ours")
        for directory in [dead, live, foreign] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("copy".utf8).write(to: directory.appendingPathComponent("file"))
        }
        FileDropStorage.removeStale(in: root)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: live.path), "another running Corta shares the folder")
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("startup cleanup finishes a removal a quit cut short")
    func staleCleanupFinishesAnInterruptedRemoval() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let interrupted = root.appendingPathComponent(".removing-\(UUID().uuidString)")
        let foreign = root.appendingPathComponent(".removing-notauuid")
        for directory in [interrupted, foreign] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        FileDropStorage.removeStale(in: root)
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path), "a name this code did not write stays")
    }

    @Test("startup cleanup does not follow a root that is a symlink")
    func staleCleanupRefusesASymlinkedRoot() throws {
        let scratch = scratchRoot()
        defer { FileDropStorage.remove(scratch) }
        let real = scratch.appendingPathComponent("real")
        let victim = real.appendingPathComponent("\(Self.deadPID)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        FileDropStorage.removeStale(in: link)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("only a pid and a uuid make a reception's name")
    func receptionNames() {
        let uuid = UUID().uuidString
        #expect(FileDropStorage.ownerPID(ofDirectoryNamed: "123-\(uuid)") == 123)
        for name in [uuid, "123", "0-\(uuid)", "-1-\(uuid)", "abc-\(uuid)", "123-notauuid", ".removing-\(uuid)"] {
            #expect(FileDropStorage.ownerPID(ofDirectoryNamed: name) == nil, "\(name)")
        }
    }

    @Test("a reception's directories are owner-only under the temporary folder's root")
    func receptionDirectory() throws {
        #expect(FileDropStorage.root.lastPathComponent == "Corta-Dropped")
        #expect(FileDropStorage.root.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        #expect(FileDropStorage.ownerPID(ofDirectoryNamed: directory.lastPathComponent) == getpid())
        for url in [root, directory, FileDropStorage.destination(in: directory)] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    /// A pane that closed, or moved on to another program, while the file was on
    /// its way: nothing reaches its input, and the user gets the path.
    @Test("a late file is not inserted, and its path and copy are kept for the user",
          arguments: ["session", "foreground", "missing"])
    func changedTargetReportsThePath(change: String) throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("sentinel")
        try Data().write(to: file)
        var reported: [URL] = []
        let saved = FileDropUndelivered.presenter
        FileDropUndelivered.presenter = { urls, _ in reported = urls }
        defer { FileDropUndelivered.presenter = saved }
        let host = CommandsTestHost()
        host.terminalView = TerminalView(frame: .zero)
        let session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), size: TerminalSize(rows: 10, columns: 60),
            workingDirectory: "/")
        defer { session.stop() }
        session.start()
        host.session = session
        let actual = try #require(host.commands.dropInputContext)
        let otherIdentity = NSObject()
        let captured: FileDropInputContext
        switch change {
        case "session":
            captured = FileDropInputContext(session: ObjectIdentifier(otherIdentity),
                foregroundGroup: actual.foregroundGroup)
        case "foreground":
            captured = FileDropInputContext(session: actual.session, foregroundGroup: actual.foregroundGroup + 1)
        default:
            captured = actual
            host.session = nil
        }
        host.commands.completeFileDrop(.init(urls: [file], directory: directory,
            failed: false, timedOut: false), context: captured)
        #expect(reported == [file])
        #expect(FileManager.default.fileExists(atPath: file.path))
        withExtendedLifetime(otherIdentity) {}
    }

    @Test("a late drop with nothing received reports nothing and removes its directory")
    func lateDropWithNothing() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        var reported = false
        let saved = FileDropUndelivered.presenter
        FileDropUndelivered.presenter = { _, _ in reported = true }
        defer { FileDropUndelivered.presenter = saved }
        FileDropUndelivered.present(.init(urls: [], directory: directory, failed: true, timedOut: true), in: nil)
        #expect(!reported)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("the report cleans file names and limits how many it lists")
    func undeliveredMessage() {
        let hostile = URL(fileURLWithPath: "/tmp/a\u{1B}]0;x\u{07}b")
        #expect(!FileDropUndelivered.message(for: [hostile]).unicodeScalars.contains { $0.value < 0x20 })
        let many = (0..<12).map { URL(fileURLWithPath: "/tmp/\($0)") }
        let lines = FileDropUndelivered.message(for: many).split(separator: "\n")
        #expect(lines.count == 11)
        #expect(lines.first == "/tmp/0")
        #expect(!lines.contains("/tmp/11"))
    }

    @Test("a request keeps itself alive until it finishes, with nothing else holding it")
    func requestOutlivesItsPane() async {
        var result: FileDropRequest.Result?
        do {
            let request = FileDropRequest(count: 1, directory: nil, timeout: .milliseconds(30)) { result = $0 }
            request.receive(LatePromiseReceiver(names: ["never"]), at: scratchRoot(), index: 0)
            request.seal()
        }
        await waitUntil("deadline reported") { result != nil }
        #expect(result?.timedOut == true)
        #expect(result?.notice != nil)
    }

    @Test("successful SFTP uploads delete their own copies, leave originals and keep failed copies for retry")
    func sftpCopyCleanup() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("upload")
        try Data("upload".utf8).write(to: file)
        let original = root.appendingPathComponent("original")
        try Data("original".utf8).write(to: original)
        let fake = FakeSFTPClient()
        fake.onTransfer = { _, _ in throw SFTPError.transport(.closed) }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect(); model.removeReceivedDrops() }
        model.receivedDropDirectories[directory] = [file]
        model.cleanUploadedDropCopies()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(model.upload([file]))
        await waitUntil("owned upload failed") {
            if case .failed = model.transfers.first?.state { return true }
            return false
        }
        let failed = try #require(model.transfers.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        fake.onTransfer = nil
        model.retryTransfer(failed.id)
        #expect(model.upload([original]))
        await waitUntil("owned upload source deleted") { !FileManager.default.fileExists(atPath: file.path) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(model.receivedDropDirectories.isEmpty)
    }

    @Test("cancelling a reception releases its completion and removes its private directory")
    func cancellationReleasesState() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        weak var retained: NSObject?
        let request: FileDropRequest
        do {
            let token = NSObject()
            retained = token
            request = FileDropRequest(count: 1, directory: directory) { _ in
                _ = token.description
            }
        }
        #expect(retained != nil)
        request.cancel()
        #expect(retained == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a timed-out partial reception keeps completed paths and never appends late paths")
    func partialTimeoutKeepsCompletedFiles() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let first = directory.appendingPathComponent("ready")
        try Data().write(to: first)
        let collection = FileDropCollection(count: 2, directory: directory)
        collection.record(first, index: 0)
        let result = collection.finish(timedOut: true)
        #expect(result.urls == [first])
        #expect(result.failed && result.timedOut)
        collection.record(directory.appendingPathComponent("late"), index: 1)
        #expect(result.urls == [first])
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

}
