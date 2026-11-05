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

    @Test("maintenance removes dead unpublished receivers but preserves published paths")
    func abandonedCleanup() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let abandoned = root.appendingPathComponent("abandoned")
        let published = root.appendingPathComponent("published")
        for directory in [abandoned, published] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PrivateFile.write(Data("99999999".utf8), to: directory.appendingPathComponent(".owner"))
        }
        try FileDropStorage.markPublished(published)
        FileDropStorage.pruneAbandoned(in: root)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: published.path))
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
