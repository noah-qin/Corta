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
    /// What macOS's `sftp-server` reports for an APFS volume: counts in
    /// 4 KiB fragments, beside a 1 MiB block size that is not their unit.
    @Test("free space is counted in fragments, not blocks")
    func volumeCountsAreFragments() {
        var info = SFTPVolumeInfo(
            blockSize: 1_048_576, fragmentSize: 4096, blocks: 242_824_745, blocksFree: 160_265_340,
            blocksAvailable: 160_265_340, files: 0, filesFree: 0, filesAvailable: 0,
            filesystemID: 0, flags: 0, nameMaximum: 255)
        let expected: SFTPBrowserModel.VolumeStatus = .available(
            free: UInt64(160_265_340) * 4096, total: UInt64(242_824_745) * 4096)
        #expect(SFTPBrowserModel.volumeStatus(for: info) == expected)
        // No fragment size reported: the block size is the unit.
        info.fragmentSize = 0
        let fallback: SFTPBrowserModel.VolumeStatus = .available(
            free: UInt64(160_265_340) * 1_048_576, total: UInt64(242_824_745) * 1_048_576)
        #expect(SFTPBrowserModel.volumeStatus(for: info) == fallback)
    }

    @Test("an authentication failure is named as one, with a way back")
    func connectAuthenticationFailure() async {
        let fake = FakeSFTPClient()
        fake.connectError = .transport(
            .authenticationFailed(diagnostics: "Permission denied (publickey)."))
        let model = SFTPBrowserModel(host: "build-box", startDirectory: nil) { _ in fake }
        model.connect()
        await waitUntil("failed") {
            guard case .failed = model.connectionState else { return false }
            return true
        }
        guard case .failed(let message) = model.connectionState else {
            Issue.record("expected a failed connection")
            return
        }
        #expect(message == L10n.format(
            "sftp.error.authentication", "build-box", "Permission denied (publickey)."))
        #expect(fake.closed, "a refused connection must not linger")

        // Retry works: the same model connects once the error clears.
        fake.connectError = nil
        fake.listings["/home/tester"] = []
        model.connect()
        await waitUntil("connected after retry") { model.connectionState == .connected }
        // No pane directory to start from: the server's REALPATH answer.
        #expect(model.currentPath == "/home/tester")
    }

    @Test("a remoteUnknown launch asks for the host and adopts the typed one")
    func hostEntry() async {
        let fake = FakeSFTPClient()
        fake.listings["/home/tester"] = []
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        #expect(model.connectionState == .needsHost)
        model.connect()  // empty field: a no-op, not a connection to ""
        #expect(model.connectionState == .needsHost)
        #expect(fake.connectedHosts.isEmpty)
        model.hostField = "  build-box  "
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        #expect(fake.connectedHosts == ["build-box"], "trimmed before use")
        #expect(model.host == "build-box")
    }

    @Test("the path field rejects relative paths honestly")
    func relativePathRejected() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.navigate(to: "relative/dir")
        #expect(model.listingError == L10n.text("sftp.path.notAbsolute"))
        #expect(model.currentPath == "/srv/app", "no navigation happened")
    }

    @Test("navigating into a directory lists it; up walks back")
    func navigation() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("sub", permissions: 0o040755)]
        fake.listings["/srv/app/sub"] = [makeEntry("deep.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        model.navigateInto(try #require(model.entries.first))
        await waitUntil("entered sub") { model.currentPath == "/srv/app/sub" }
        #expect(model.entries.map(\.name) == ["deep.txt"])

        model.navigateUp()
        await waitUntil("back up") { model.currentPath == "/srv/app" }
        #expect(model.entries.map(\.name) == ["sub"])
    }

    @Test("a permission-denied listing keeps the current directory and says why")
    func listingPermissionDenied() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        fake.listingErrors["/root"] = .server(
            SFTPStatus(code: .permissionDenied, message: Array("denied".utf8)))
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.navigate(to: "/root")
        await waitUntil("error shown") { model.listingError != nil }
        #expect(
            model.listingError
                == L10n.format("sftp.error.permissionDenied", "build-box", "denied"))
        #expect(model.currentPath == "/srv/app")
    }

    @Test("new directory, rename and delete reach the client with full paths")
    func directoryOperations() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("a.txt"), makeEntry("old", permissions: 0o040755),
        ]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        model.requestNewDirectory()
        let prompt = try #require(model.textPrompt)
        #expect(prompt.message.contains("/srv/app"))
        model.commitTextPrompt("newdir")
        await waitUntil("mkdir") { fake.madeDirectories == ["/srv/app/newdir"] }

        let entry = try #require(model.entries.first { $0.name == "a.txt" })
        model.requestRename(entry)
        #expect(model.textPrompt?.initialText == "a.txt")
        model.commitTextPrompt("b.txt")
        await waitUntil("rename") { !fake.renamed.isEmpty }
        #expect(fake.renamed.first.map { [$0.from, $0.to] } == ["/srv/app/a.txt", "/srv/app/b.txt"])
    }

    @Test("a name with a slash is rejected before the server hears about it")
    func invalidNameRejected() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.requestNewDirectory()
        model.commitTextPrompt("a/b")
        #expect(model.listingError == L10n.text("sftp.name.invalid"))
        #expect(fake.madeDirectories.isEmpty)
    }

    @Test("delete asks, naming host, path and entry count, then removes a directory as one")
    func deleteConfirmation() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("a.txt"), makeEntry("old", permissions: 0o040755),
        ]
        fake.listings["/srv/app/old"] = [makeEntry("."), makeEntry(".."), makeEntry("x")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }

        // A directory's confirmation names host and path and counts what
        // is inside ("." and ".." are the server's bookkeeping, excluded).
        model.selection = ["old"]
        model.requestDelete(model.selectedEntries)
        await waitUntil("directory confirmation") { model.deleteConfirmation != nil }
        let confirmation = try #require(model.deleteConfirmation)
        #expect(confirmation.title.contains("build-box"))
        #expect(confirmation.message.contains("/srv/app/old"))
        #expect(confirmation.message.contains("build-box"))
        #expect(confirmation.message.contains("1"))

        model.confirmDelete()
        await waitUntil("deleted") { !fake.removedDirectories.isEmpty }
        #expect(fake.removedDirectories == ["/srv/app/old"])
        #expect(fake.removed.isEmpty, "a directory goes to rmdir, never to remove")
    }

    /// The confirmation names a path; the delete must act on that path even
    /// when the listing moved on before the user confirmed — the same name
    /// in the new directory is a different file.
    @Test("delete removes what the confirmation named, wherever the listing is now")
    func deleteUsesTheConfirmedDirectory() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt")]
        fake.listings["/srv/other"] = [makeEntry("a.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        model.selection = ["a.txt"]
        model.requestDelete(model.selectedEntries)
        await waitUntil("confirmation") { model.deleteConfirmation != nil }
        #expect(model.deleteConfirmation?.message.contains("/srv/app/a.txt") == true)

        model.navigate(to: "/srv/other")
        await waitUntil("navigated") { model.currentPath == "/srv/other" }
        model.confirmDelete()
        await waitUntil("deleted") { !fake.removed.isEmpty }
        #expect(fake.removed == ["/srv/app/a.txt"])
    }

    // MARK: - Transfers

    @Test("a download with no conflict runs under .fail and completes")
    func downloadNoConflict() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("a.txt", size: 100)]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        let destination = directory.appendingPathComponent("a.txt")
        model.pickDownloadDestination = { _ in .file(destination) }
        model.selection = ["a.txt"]
        model.requestDownload()

        await waitUntil("done") {
            guard let transfer = model.transfers.first, case .done = transfer.state else {
                return false
            }
            return true
        }
        let call = try #require(fake.transferCalls.first)
        #expect(!call.isUpload)
        #expect(call.remotePath == "/srv/app/a.txt")
        #expect(call.localPath == destination.path)
        #expect(call.policy == "fail")
        #expect(call.disposition == .remove)
        #expect(model.transfers.first?.state == .done(bytes: 100))
        #expect(model.conflictPrompts.isEmpty)
    }
}
