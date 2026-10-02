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

import CortaTerminal
import Foundation
import Synchronization
import Testing

@testable import Corta

/// The browser's Finder-like behaviour: sorting, hidden files, Back and
/// Forward, cancelling and correcting a connection, uploads from a drop, and
/// the transfer list's rate, time left and Clear. All through
/// `FakeSFTPClient`; nothing touches ssh or the network.

@MainActor
private func connected(
    _ fake: FakeSFTPClient, at path: String = "/srv"
) async -> SFTPBrowserModel {
    let model = SFTPBrowserModel(host: "build-box", startDirectory: path) { _ in fake }
    model.connect()
    await waitUntil("connected") { model.connectionState == .connected }
    return model
}

private func entry(
    _ name: String, directory: Bool = false, size: UInt64? = 1, modified: UInt32? = nil
) -> SFTPEntry {
    SFTPEntry(
        filename: Array(name.utf8),
        attributes: SFTPAttributes(
            size: size, permissions: directory ? 0o040755 : 0o100644,
            modificationTime: modified))
}

@MainActor
struct SFTPBrowserSortingTests {
    @Test("folders stay first whichever column sorts, and ties fall back to the name")
    func sorting() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [
            entry("b.txt", size: 30, modified: 300), entry("a.txt", size: 10, modified: 100),
            entry("zdir", directory: true, size: nil), entry("adir", directory: true, size: nil),
            entry("c.txt", size: 10, modified: 200),
        ]
        let model = await connected(fake)
        #expect(model.entries.map(\.name) == ["adir", "zdir", "a.txt", "b.txt", "c.txt"])

        model.sortColumn = .size
        model.sortAscending = false
        // Equal sizes (the folders have none) keep the name order.
        #expect(model.entries.map(\.name) == ["adir", "zdir", "b.txt", "a.txt", "c.txt"])

        model.sortColumn = .modified
        model.sortAscending = true
        #expect(model.entries.map(\.name).suffix(3) == ["a.txt", "c.txt", "b.txt"])
    }

    @Test("dot files are hidden until asked for, counted, and dropped from the selection")
    func hiddenFiles() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [entry(".env"), entry(".git", directory: true), entry("app.py")]
        let model = await connected(fake)
        #expect(model.entries.map(\.name) == ["app.py"])
        #expect(model.hiddenEntryCount == 2)

        model.showsHiddenFiles = true
        #expect(model.entries.map(\.name) == [".git", ".env", "app.py"])
        #expect(model.hiddenEntryCount == 0)
        model.selection = [".env", "app.py"]

        model.showsHiddenFiles = false
        #expect(model.selection == ["app.py"], "a hidden row cannot stay selected")
    }
}

@MainActor
struct SFTPBrowserHistoryTests {
    @Test("Back and Forward walk the visited directories; a refresh is not a step")
    func backAndForward() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [entry("app", directory: true)]
        fake.listings["/srv/app"] = [entry("src", directory: true)]
        fake.listings["/srv/app/src"] = []
        let model = await connected(fake)
        #expect(!model.canGoBack && !model.canGoForward)

        model.navigateInto(model.entries[0])
        await waitUntil("in app") { model.currentPath == "/srv/app" }
        model.navigateInto(model.entries[0])
        await waitUntil("in src") { model.currentPath == "/srv/app/src" }
        model.refresh()
        await waitUntil("refreshed") { !model.isLoading }
        #expect(model.backStack == ["/srv", "/srv/app"])

        model.navigateBack()
        await waitUntil("back to app") { model.currentPath == "/srv/app" }
        #expect(model.canGoForward)
        model.navigateBack()
        await waitUntil("back to srv") { model.currentPath == "/srv" }
        #expect(!model.canGoBack)
        #expect(model.forwardStack == ["/srv/app/src", "/srv/app"])

        model.navigateForward()
        await waitUntil("forward to app") { model.currentPath == "/srv/app" }
        // A new visit from the middle of the history drops what was ahead.
        model.navigate(to: "/srv")
        await waitUntil("visited srv") { model.currentPath == "/srv" }
        #expect(!model.canGoForward)
    }

    @Test("a directory that fails to open is not a step to go back to")
    func failedVisitLeavesHistory() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = []
        fake.listingErrors["/nope"] = .server(SFTPStatus(code: .noSuchFile))
        let model = await connected(fake)
        model.navigate(to: "/nope")
        await waitUntil("error shown") { model.listingError != nil }
        #expect(model.currentPath == "/srv")
        #expect(model.backStack.isEmpty)
    }
}

@MainActor
struct SFTPBrowserConnectionTests {
    @Test("Cancel while connecting goes back to the host field with the name kept")
    func cancelWhileConnecting() async {
        let fake = FakeSFTPClient()
        let model = SFTPBrowserModel(host: "slow-box", startDirectory: nil) { _ in fake }
        var abandoned: [String] = []
        model.onHostAbandoned = { abandoned.append($0) }
        model.connect()
        #expect(model.connectionState == .connecting)
        model.cancelConnect()
        #expect(model.connectionState == .needsHost)
        #expect(model.hostField == "slow-box")
        #expect(model.host == nil)
        #expect(abandoned == ["slow-box"])
    }

    @Test("Retry after a failure uses the corrected name in the field")
    func retryWithCorrectedHost() async {
        let failing = FakeSFTPClient()
        failing.connectError = .transport(.hostUnreachable(diagnostics: "no route"))
        let working = FakeSFTPClient()
        working.listings["/home/tester"] = []
        let asked = Mutex<[String]>([])
        let model = SFTPBrowserModel(host: "typo-box", startDirectory: nil) { host in
            asked.withLock { $0.append(host) }
            return host == "typo-box" ? failing : working
        }
        model.connect()
        await waitUntil("failed") { model.isFailed }
        #expect(model.hostField == "typo-box", "the failed name is left to correct")

        model.hostField = "build-box"
        model.retry()
        await waitUntil("connected") { model.connectionState == .connected }
        #expect(asked.withLock { $0 } == ["typo-box", "build-box"])
        #expect(model.host == "build-box")
    }

    @Test("the window title is the host, never host:path")
    func titleIsTheHost() async {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = []
        var titles: [String] = []
        let model = SFTPBrowserModel(host: "build-box", startDirectory: "/srv") { _ in fake }
        model.onTitleChange = { titles.append($0) }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        #expect(titles.last == "build-box")
    }
}

@MainActor
struct SFTPBrowserDropTests {
    @Test("dropped files upload into the current folder or the folder they landed on")
    func dropsUpload() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [entry("logs", directory: true)]
        let model = await connected(fake)
        let local = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: local) }
        let file = local.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)

        #expect(model.upload([file]))
        #expect(model.upload([file], into: "/srv/logs"))
        // Not a file URL: nothing to upload.
        #expect(!model.upload([URL(string: "https://example.com/a")!]))
        await waitUntil("both uploads ran") { fake.transferCalls.count == 2 }
        #expect(Set(fake.transferCalls.map(\.remotePath)) == ["/srv/notes.txt", "/srv/logs/notes.txt"])
    }
}

@MainActor
struct SFTPDragExportTests {
    @Test("a file dragged to Finder downloads into a private folder that closing removes")
    func dragExport() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [entry("notes.txt"), entry("logs", directory: true)]
        fake.onTransfer = { call, _ in
            try Data("remote".utf8).write(to: URL(fileURLWithPath: call.localPath))
        }
        let model = await connected(fake)
        let file = try #require(model.entries.first { $0.name == "notes.txt" })
        let url = try await model.exportForDrag(file)
        #expect(url.lastPathComponent == "notes.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "remote")
        let folder = url.deletingLastPathComponent()
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(model.transfers.count == 1, "the drag has a progress row like any download")

        let directory = try #require(model.entries.first { $0.name == "logs" })
        await #expect(throws: (any Error).self) { try await model.exportForDrag(directory) }

        model.removeDragStaging()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

@MainActor
struct SFTPTransferListTests {
    @Test("the rate needs two samples half a second apart, then follows a third of the way")
    func rateSmoothing() {
        var transfer = SFTPTransferQueue.Transfer(
            id: UUID(), isUpload: false, name: "a", remotePath: "/a",
            localURL: URL(fileURLWithPath: "/tmp/a"), host: "h",
            state: .active(completed: 0, total: 4000))
        transfer = SFTPTransferQueue.updatedRate(transfer, completed: 0, now: 10)
        #expect(transfer.bytesPerSecond == nil)
        transfer = SFTPTransferQueue.updatedRate(transfer, completed: 500, now: 10.2)
        #expect(transfer.bytesPerSecond == nil, "too soon for a sample")
        transfer = SFTPTransferQueue.updatedRate(transfer, completed: 1000, now: 11)
        #expect(transfer.bytesPerSecond == 1000)
        transfer = SFTPTransferQueue.updatedRate(transfer, completed: 2000, now: 11.5)
        // Instant rate 2000 B/s; the shown rate moves a third of the way.
        #expect(abs((transfer.bytesPerSecond ?? 0) - 1333.33) < 0.1)
        transfer.state = .active(completed: 2000, total: 4000)
        #expect(abs((transfer.remainingSeconds ?? 0) - 1.5) < 0.01)
    }

    @Test("the progress line shows only what is known")
    func progressDetail() {
        let fresh = SFTPBrowserModel.progressDetail(
            completed: 0, total: 1_000_000, bytesPerSecond: nil, remainingSeconds: nil)
        #expect(!fresh.contains("/s"))
        let running = SFTPBrowserModel.progressDetail(
            completed: 500_000, total: 1_000_000, bytesPerSecond: 100_000, remainingSeconds: 5)
        #expect(running.split(separator: "·").count == 3)
        let unknownSize = SFTPBrowserModel.progressDetail(
            completed: 2048, total: nil, bytesPerSecond: nil, remainingSeconds: nil)
        #expect(unknownSize == SFTPBrowserModel.formattedByteCount(2048))
    }

    @Test("Clear removes finished rows only; a finished download reports its file")
    func clearAndFinish() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [entry("a.txt"), entry("b.txt")]
        let gate = AsyncStream<Void>.makeStream()
        fake.onTransfer = { call, _ in
            if call.remotePath == "/srv/b.txt" {
                for await _ in gate.stream { break }
            }
        }
        let model = await connected(fake)
        let local = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: local) }
        var finished: Result<URL, SFTPTransferQueue.TransferFailure>?
        model.transferQueue.enqueue(
            .init(isUpload: false, remotePath: "/srv/a.txt", localURL: local.appendingPathComponent("a.txt"))
        ) { finished = $0 }
        model.transferQueue.enqueue(
            .init(isUpload: false, remotePath: "/srv/b.txt", localURL: local.appendingPathComponent("b.txt")))
        await waitUntil("a done") { finished != nil }
        #expect(try finished?.get() == local.appendingPathComponent("a.txt"))
        #expect(model.transferQueue.activeCount == 1)

        model.transferQueue.clearFinished()
        #expect(model.transfers.map(\.name) == ["b.txt"], "a running transfer stays")
        gate.continuation.yield()
        gate.continuation.finish()
        await waitUntil("b done") { model.transferQueue.activeCount == 0 }
    }
}
