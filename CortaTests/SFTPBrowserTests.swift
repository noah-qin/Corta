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

/// The SFTP browser's app layer: gating, the command-table entry,
/// the model's navigation and error states, the transfer queue, and the
/// conflict-choice mapping. Every engine interaction goes through
/// `FakeSFTPClient` over the `SFTPClient` protocol seam — no ssh, no
/// network, and local filesystem staging confined to per-test temp
/// directories that are removed afterwards.

@MainActor
func connectedModel(
    fake: FakeSFTPClient,
    host: String = "build-box",
    startDirectory: String? = "/srv/app"
) async -> SFTPBrowserModel {
    let model = SFTPBrowserModel(host: host, startDirectory: startDirectory) { host in
        fake.connectedHosts.append(host)
        return fake
    }
    model.connect()
    await waitUntil("connected") { model.connectionState == .connected }
    return model
}

// MARK: - Gating and command wiring

@MainActor
struct SFTPBrowserWiringTests {
    @Test("the menu item is offered exactly for remote panes")
    func gating() {
        #expect(
            PaneRemote.canBrowseFiles(
                state: .remote(host: "h", directory: "/d", provenance: .osc7)))
        #expect(PaneRemote.canBrowseFiles(state: .remoteUnknown(provenance: .foregroundProcess)))
        #expect(!PaneRemote.canBrowseFiles(state: .local))
        #expect(!PaneRemote.canBrowseFiles(state: .unknown))
    }

    @Test("the command table entry is complete and unbound by default")
    func commandTable() {
        let command = TerminalCommand.browseRemoteFiles
        #expect(command.rawValue == "browse-remote-files")
        #expect(!command.title.isEmpty)
        #expect(command.title == L10n.text("command.browseRemoteFiles"))
        #expect(command.category == .terminal)
        #expect(command.defaultShortcut == nil)
        #expect(command.action == #selector(PaneRemote.browseRemoteFiles(_:)))
    }

    @Test("the Shell menu carries the item, after the directory commands")
    func shellMenu() throws {
        let menu = try #require(NSApp.mainMenu)
        let shell = try #require(
            menu.items.first { $0.title == L10n.text("menu.shell") || $0.title == "Shell" }?.submenu)
        let actions = shell.descendantItems.compactMap(\.action)
        let browse = try #require(
            actions.firstIndex(of: #selector(PaneRemote.browseRemoteFiles(_:))))
        let directories = try #require(
            actions.firstIndex(of: #selector(PaneCommands.revealWorkingDirectoryInFinder(_:))))
        let state = try #require(
            actions.firstIndex(of: #selector(PaneCommands.clearScreen(_:))))
        // In the directory-navigation group: after those, before the state
        // commands, within the same separator-delimited run.
        #expect(browse > directories && browse < state)
    }
}

// MARK: - Pure helpers

// MARK: - The model against the fake

@MainActor
struct SFTPBrowserModelTests {
    @Test("reusing an existing host does not create a second client")
    func reuseHostBeforeConnecting() async {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        var requestedHost: String?
        model.shouldStartConnection = { host in
            requestedHost = host
            return false
        }
        model.hostField = " build-box "
        model.connect()
        await Task.yield()
        #expect(requestedHost == "build-box")
        #expect(fake.connectedHosts.isEmpty)
        #expect(model.connectionState == .needsHost)
    }

    @Test("a host that could not be typed in the connect sheet is refused before ssh")
    func invalidHostIsRefused() async {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        model.hostField = "evil;touch x"
        model.connect()
        await Task.yield()
        #expect(fake.connectedHosts.isEmpty)
        #expect(model.connectionState == .failed(message: RemoteConnectForm.message(.host)))
        #expect(model.hostField == "evil;touch x", "left in the field to correct")
    }

    @Test("a typed user, port and key name the connection and reach ssh with it")
    func typedFieldsNameTheConnection() async throws {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        let host = "fields-\(UUID().uuidString.prefix(8).lowercased())"
        model.fields = SSHTargetFields(host: host, user: "deploy", port: "2222")
        model.connect()
        await Task.yield()
        #expect(fake.connectedHosts == ["deploy@\(host):2222"])
        #expect(model.host == "deploy@\(host):2222")
        // How `SFTPConnection.forApp` spawns it, and remote editing after it.
        #expect(SSHTarget(key: "deploy@\(host):2222")?.sshOptions == ["-l", "deploy", "-p", "2222"])
    }

    /// A key chosen or cleared after a failed sign-in makes Retry a new
    /// connection, though the place — and the display name — is the same.
    @Test("retry with another key is another connection")
    func retryWithAnotherKey() async throws {
        let fake = FakeSFTPClient()
        fake.connectError = .transport(.authenticationFailed(diagnostics: "Permission denied"))
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("corta-key-\(UUID().uuidString)")
        try Data("key".utf8).write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }
        model.fields = SSHTargetFields(host: "box")
        model.connect()
        await waitUntil("the first sign-in fails") { model.isFailed }
        model.fields.identityFile = key.path
        model.retry()
        await waitUntil("the retry connects") { fake.connectedHosts.count == 2 }
        #expect(fake.connectedHosts == ["box", "box -i \(key.path)"])
        #expect(model.displayHost == "box")
    }

    @Test("a form problem is said in its own words, and nothing is spawned")
    func formProblemIsShown() async {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: nil, startDirectory: nil) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        model.fields = SSHTargetFields(host: "deploy@box", user: "other")
        model.connect()
        await Task.yield()
        #expect(fake.connectedHosts.isEmpty)
        #expect(model.connectionState == .failed(message: RemoteConnectForm.message(.userTwice)))
        #expect(model.fields.user == "other", "left in the fields to correct")
    }

    /// A host the pane *reported* is a suggestion: the window opens on the
    /// host-entry step with the name prefilled, connects to nothing until
    /// Connect is pressed, and then connects to whatever the field holds
    /// — the user's word, corrected or not.
    @Test("a suggested host is prefilled, not connected to, until the user says so")
    func suggestedHostWaitsForTheUser() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = SFTPBrowserModel(
            host: nil, startDirectory: "/srv/app", suggestedHost: "reported-box"
        ) { host in
            fake.connectedHosts.append(host)
            return fake
        }
        defer { model.disconnect() }
        #expect(model.connectionState == .needsHost)
        #expect(model.host == nil)
        #expect(model.hostField == "reported-box")
        #expect(model.suggestedHost == "reported-box")
        #expect(fake.connectedHosts.isEmpty, "presenting the window spawns nothing")

        // The user corrects the name to the alias ssh actually knows.
        model.hostField = "box"
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        #expect(fake.connectedHosts == ["box"])
        #expect(model.host == "box")
        #expect(model.currentPath == "/srv/app", "the reported directory is still the start")
    }

    /// A decided host never carries a suggestion: the suggestion is only
    /// for the question, and there is none to ask.
    @Test("a decided host ignores any suggestion")
    func decidedHostHasNoSuggestion() {
        let model = SFTPBrowserModel(
            host: "box", startDirectory: nil, suggestedHost: "reported-box")
        #expect(model.suggestedHost == nil)
        #expect(model.hostField == "")
        #expect(model.connectionState == .connecting)
    }

    /// A server's entry name is one path component or it is nothing: a
    /// hostile `../../.zshrc` would otherwise be appended to a chosen
    /// download folder and land outside it.
    @Test("an entry name that is not a plain component is dropped from the listing")
    func nonComponentNamesAreDropped() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("ok.txt", permissions: 0o100644),
            makeEntry("../../.zshrc", permissions: 0o100644),
            makeEntry("sub/child", permissions: 0o100644),
            makeEntry("", permissions: 0o100644),
        ]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        #expect(model.entries.map(\.name) == ["ok.txt"])
        #expect(!SFTPBrowserModel.isPlainEntryName("a/b"))
        #expect(!SFTPBrowserModel.isPlainEntryName("a\0b"))
        #expect(SFTPBrowserModel.isPlainEntryName("a b's — ✨.txt"))
    }

    @Test("connecting lists the pane's directory, filtering the server's dot entries")
    func connectLists() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [
            makeEntry("."), makeEntry(".."),
            makeEntry("zeta.txt", permissions: 0o100644),
            makeEntry("sub", permissions: 0o040755),
            makeEntry("alpha.txt", permissions: 0o100644),
        ]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        #expect(model.connectionState == .connected)
        #expect(model.currentPath == "/srv/app")
        // Directories first, then by name; "." and ".." never shown.
        #expect(model.entries.map(\.name) == ["sub", "alpha.txt", "zeta.txt"])
        #expect(model.entries.map(\.kind) == [.directory, .file, .file])
        #expect(fake.connectedHosts == ["build-box"])
    }

    @Test("a server without statvfs reports volume information as unavailable")
    func volumeUnsupported() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        await waitUntil("volume probed") { model.volumeStatus != .unknown }
        #expect(model.volumeStatus == .unsupported)
    }

    @Test("a server with statvfs reports free space")
    func volumeAvailable() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = []
        fake.volumeInfoResult = SFTPVolumeInfo(
            blockSize: 4096, fragmentSize: 4096, blocks: 1000, blocksFree: 500,
            blocksAvailable: 400, files: 0, filesFree: 0, filesAvailable: 0,
            filesystemID: 0, flags: 0, nameMaximum: 255)
        let model = await connectedModel(fake: fake)
        defer { model.disconnect() }
        await waitUntil("volume probed") { model.volumeStatus != .unknown }
        // Spelled out: the inline literal arithmetic inside `#expect` is a
        // type-check timeout on Xcode 27's compiler.
        let expected: SFTPBrowserModel.VolumeStatus = .available(
            free: UInt64(400 * 4096), total: UInt64(1000 * 4096))
        #expect(model.volumeStatus == expected)
    }

    @Test("remote unsigned sizes remain displayable across the signed boundary")
    func oversizedByteCounts() {
        #expect(!SFTPBrowserModel.formattedByteCount(0).isEmpty)
        #expect(!SFTPBrowserModel.formattedByteCount(UInt64(Int64.max)).isEmpty)
        let oversized = UInt64(Int64.max) + 1
        #expect(SFTPBrowserModel.formattedByteCount(oversized) == "\(oversized) B")
        #expect(SFTPBrowserModel.describe(size: UInt64.max, modified: nil) == "\(UInt64.max) B")
    }

    @Test("overflowing statvfs counters are unknown instead of trapping")
    func overflowingVolumeCounters() {
        var info = SFTPVolumeInfo(
            blockSize: 2, fragmentSize: 2, blocks: .max, blocksFree: 1,
            blocksAvailable: 1, files: 0, filesFree: 0, filesAvailable: 0,
            filesystemID: 0, flags: 0, nameMaximum: 255)
        #expect(SFTPBrowserModel.volumeStatus(for: info) == .unknown)
        info.blocks = 2
        info.blocksAvailable = .max
        #expect(SFTPBrowserModel.volumeStatus(for: info) == .unknown)
        info.blockSize = 1
        info.fragmentSize = 1
        info.blocks = .max
        #expect(SFTPBrowserModel.volumeStatus(for: info) == .available(free: .max, total: .max))
    }
}

@MainActor
struct SFTPTransferQueueLifecycleTests {
    @Test("a Retry after Change Host never runs on the new host")
    func retryStaysOnItsHost() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("secrets.env")
        try Data("TOKEN=fake".utf8).write(to: source)
        let first = FakeSFTPClient()
        first.onTransfer = { _, _ in throw SFTPError.transport(.connectionLost) }
        let queue = SFTPTransferQueue()
        queue.client = first
        queue.host = "host-a"
        queue.enqueue(.init(isUpload: true, remotePath: "/srv/secrets.env", localURL: source))
        await waitUntil("failed") {
            guard case .failed(_, true) = queue.transfers.first?.state else { return false }
            return true
        }
        // Change Host: the failed row stays, the queue moves to another machine.
        queue.disconnect()
        let second = FakeSFTPClient()
        queue.client = second
        queue.host = "host-b"
        let id = try #require(queue.transfers.first?.id)
        queue.retryTransfer(id)
        #expect(second.transferCalls.isEmpty, "nothing queued for host-a reaches host-b")
        guard case .failed(_, let retryable) = queue.transfers.first?.state else {
            Issue.record("expected the row to fail, not run")
            return
        }
        #expect(!retryable)
        #expect(queue.transfers.first?.host == "host-a")
    }

    @Test func cancellingConflictRemovesPromptAndCannotStartLater() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("existing".utf8).write(to: destination)
        let fake = FakeSFTPClient()
        let queue = SFTPTransferQueue()
        queue.client = fake
        queue.host = "test-host"
        queue.enqueue(.init(isUpload: false, remotePath: "/existing.txt", localURL: destination))
        await waitUntil("conflict") { !queue.conflictPrompts.isEmpty }
        let prompt = try #require(queue.conflictPrompts.first)
        queue.cancelTransfer(prompt.transferID)
        #expect(queue.conflictPrompts.isEmpty)
        queue.resolveConflict(prompt.id, choice: .overwrite)
        #expect(queue.transfers.first?.state == .cancelled(partialKept: false))
        #expect(fake.transferCalls.isEmpty)
    }

    @Test func disconnectBeforePreflightPreventsTransfer() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeSFTPClient()
        let queue = SFTPTransferQueue()
        queue.client = fake
        queue.host = "test-host"
        queue.enqueue(.init(isUpload: false, remotePath: "/new.txt",
                            localURL: directory.appendingPathComponent("new.txt")))
        queue.disconnect()
        await Task.yield()
        #expect(queue.transfers.first?.state == .cancelled(partialKept: false))
        #expect(queue.conflictPrompts.isEmpty)
        #expect(fake.transferCalls.isEmpty)
    }
}
