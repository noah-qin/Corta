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
import SwiftUI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Corta

@MainActor
struct SFTPDragProviderTests {
    /// Simulate a synchronous AppKit consumer with a bounded main-thread
    /// wait. Production code must never use this testing-only pattern.
    private func waitWhileMainThreadIsOccupied(_ ready: DispatchSemaphore) -> DispatchTimeoutResult {
        ready.wait(timeout: .now() + .seconds(2 * testTimeoutScale))
    }

    @Test("URL and text load with the main thread occupied and never download")
    func linkDoesNotNeedMainActor() throws {
        let exported = Mutex(false)
        let url = try #require(URL(string: "sftp://user@example.com:2222/a%20b/项目.txt"))
        let provider = SFTPDragItem(name: "项目.txt", remoteURL: url) {
            exported.withLock { $0 = true }
            throw CancellationError()
        }.itemProvider()
        #expect(provider.suggestedName == "项目.txt")
        #expect(provider.registeredTypeIdentifiers.first == UTType.data.identifier)
        for type in [UTType.url, .utf8PlainText] {
            let result = Mutex<Data?>(nil)
            let ready = DispatchSemaphore(value: 0)
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                #expect(error == nil)
                result.withLock { $0 = data }
                ready.signal()
            }
            // Reproduce a synchronous pasteboard consumer during AppKit drag
            // tracking. A main-actor loader cannot run until this returns.
            #expect(waitWhileMainThreadIsOccupied(ready) == .success)
            #expect(result.withLock { $0 } == Data(url.absoluteString.utf8))
        }
        #expect(!exported.withLock { $0 })
    }

    @Test("file promise downloads asynchronously, keeping its original directory")
    func fileDownloadDoesNotBlockAndKeepsSource() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [makeEntry("notes.txt")]
        let gate = AsyncStream<Void>.makeStream()
        fake.onTransfer = { call, _ in
            for await _ in gate.stream { }
            try Data("remote file".utf8).write(to: URL(fileURLWithPath: call.localPath))
        }
        let model = SFTPBrowserModel(host: "user@example.com:2222", startDirectory: "/srv") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { gate.continuation.finish(); model.disconnect(); model.removeDragStaging(); SFTPRemoteDrag.end() }
        let entry = try #require(model.entries.first)
        let provider = model.dragItem(for: entry).itemProvider()
        #expect(fake.transferCalls.isEmpty)
        model.navigate(to: "/other")
        await waitUntil("navigation") { !model.isLoading }
        let result = Mutex<Result<Data, any Error>?>(nil)
        provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
            result.withLock { value in
                value = Result {
                    if let error { throw error }
                    return try Data(contentsOf: #require(url))
                }
            }
        }
        await waitUntil("download started while main actor remains responsive") { !fake.transferCalls.isEmpty }
        #expect(fake.transferCalls.first?.remotePath == "/srv/notes.txt")
        #expect(result.withLock { $0 } == nil)
        #expect(model.transfers.count == 1)
        gate.continuation.finish()
        await waitUntil("file promise completion") { result.withLock { $0 != nil } }
        #expect(try result.withLock { try $0?.get() } == Data("remote file".utf8))
    }

    @Test("the real table publishes a synchronously readable link without downloading")
    func tablePasteboardNegotiation() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [makeEntry("notes.txt")]
        let model = SFTPBrowserModel(host: "user@example.com:2222", startDirectory: "/srv") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SFTPBrowserView(model: model))
        window.orderFront(nil)
        defer { window.close(); model.disconnect(); model.removeDragStaging(); SFTPRemoteDrag.end() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        await waitUntil("table rows") {
            window.contentView.map { table(in: $0)?.numberOfRows == 1 } ?? false
        }
        let listing = try #require(window.contentView.flatMap { table(in: $0) })
        let outline = try #require(listing as? NSOutlineView)
        let row = try #require(outline.item(atRow: 0))
        let writer = try #require(outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: row))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([writer]))
        #expect(SFTPRemoteDrag.isFilePromise(pasteboard.types ?? []))
        let terminal = TerminalView(frame: .zero)
        terminal.remotePathsForDrop = { urls in urls.map(\.path) }
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: true) == ["/srv/notes.txt"])
        terminal.remotePathsForDrop = { _ in [] }
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: true).isEmpty, "another host is refused")
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: false).isEmpty,
                "the browser's own promise is not taken as a local file")
        #expect(SFTPDropTargetView.fileURLs(pasteboard).isEmpty, "not an upload, even with fileURL advertised")
        #expect(pasteboard.string(forType: .URL) == "sftp://user@example.com:2222/srv/notes.txt")
        #expect(pasteboard.string(forType: .string) == "sftp://user@example.com:2222/srv/notes.txt")
        #expect(fake.transferCalls.isEmpty)
    }

    @Test("promised file URLs are never read while a drag is negotiated")
    func promisedLocalURLMustNotBeMaterialized() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); SFTPRemoteDrag.end() }
        let promise = try #require(NSFilePromiseReceiver.readableDraggedTypes.first)
        let item = NSPasteboardItem()
        let probe = PromisedURLProbe()
        item.setData(Data(), forType: .init(promise))
        item.setDataProvider(probe, forTypes: [.fileURL])
        #expect(pasteboard.writeObjects([item]))
        let remote = try #require(URL(string: "sftp://user@example.com:2222/srv/notes.txt"))
        SFTPRemoteDrag.begin(remote)
        let terminal = TerminalView(frame: .zero)
        terminal.remotePathsForDrop = { urls in urls.map(\.path) }
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: true) == ["/srv/notes.txt"])
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: false).isEmpty)
        terminal.remotePathsForDrop = { _ in [] }
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: true).isEmpty)
        #expect(SFTPDropTargetView.fileURLs(pasteboard).isEmpty)
        #expect(probe.requests == 0, "the tracking call must not read a promised file URL")
        let deadline = SuspendingClock.now + .seconds(2)
        var materialized: [String] = []
        while materialized != ["/tmp/materialized-promise.txt"], SuspendingClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            materialized = terminal.droppedPaths(from: pasteboard, isLocalDrag: false)
        }
        #expect(probe.requests >= 1)
        #expect(probe.mainThreadRequests == 0, "materializing waits on a background thread, not this one")
        #expect(materialized == ["/tmp/materialized-promise.txt"])
        #expect(SFTPDropTargetView.fileURLs(pasteboard).map(\.path) == ["/tmp/materialized-promise.txt"])

        SFTPRemoteDrag.end()
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/ordinary-file.txt", forType: .fileURL)
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: false) == ["/tmp/ordinary-file.txt"])
    }

    @Test("a resident file URL beside a promise is the local path, not the remote drag")
    func residentFileURLBesideAPromiseIsLocal() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); SFTPRemoteDrag.end() }
        let promise = try #require(NSFilePromiseReceiver.readableDraggedTypes.first)
        let item = NSPasteboardItem()
        item.setData(Data(), forType: .init(promise))
        item.setString("file:///tmp/icloud-placeholder.txt", forType: .fileURL)
        #expect(pasteboard.writeObjects([item]))
        let remote = try #require(URL(string: "sftp://user@example.com:2222/srv/notes.txt"))
        SFTPRemoteDrag.begin(remote)
        let terminal = TerminalView(frame: .zero)
        terminal.remotePathsForDrop = { urls in urls.map(\.path) }
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: true) == ["/srv/notes.txt"])
        #expect(terminal.droppedPaths(from: pasteboard, isLocalDrag: false) == ["/tmp/icloud-placeholder.txt"])
        #expect(SFTPDropTargetView.fileURLs(pasteboard).map(\.path) == ["/tmp/icloud-placeholder.txt"])
    }

    @Test("ending the drag session drops the remote path before the lifetime does")
    func dragSessionEndClearsTheRecord() throws {
        let url = try #require(URL(string: "sftp://user@example.com/srv/notes.txt"))
        let promise = NSPasteboard.PasteboardType(try #require(NSFilePromiseReceiver.readableDraggedTypes.first))
        let first = SFTPRemoteDrag.begin(url)
        SFTPRemoteDrag.attach("older")
        let second = SFTPRemoteDrag.begin(url)
        SFTPRemoteDrag.attach("newer")
        #expect(SFTPRemoteDrag.detach("older") == first)
        SFTPRemoteDrag.end(token: first)
        #expect(SFTPRemoteDrag.url(forPasteboardTypes: [promise]) == url, "a newer drag is still the current one")
        let ended = SFTPRemoteDrag.detach("newer")
        #expect(ended == second)
        SFTPRemoteDrag.end(token: second)
        #expect(SFTPRemoteDrag.url(forPasteboardTypes: [promise]) == nil)
    }

    @Test("file promise errors and cancellation complete the provider", arguments: [false, true])
    func fileRequestFailure(cancel: Bool) async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [makeEntry("notes.txt")]
        fake.onTransfer = { _, _ in
            if cancel { try await Task.sleep(for: .seconds(60)) }
            throw SFTPError.transport(.closed)
        }
        let model = SFTPBrowserModel(host: "example.com", startDirectory: "/srv") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { model.disconnect(); model.removeDragStaging(); SFTPRemoteDrag.end() }
        let provider = model.dragItem(for: try #require(model.entries.first)).itemProvider()
        let completed = Mutex<Bool?>(nil)
        provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
            completed.withLock { $0 = url == nil && error != nil }
        }
        await waitUntil("transfer started") { !fake.transferCalls.isEmpty }
        if cancel { model.cancelTransfer(try #require(model.transfers.first).id) }
        await waitUntil("provider failed") { completed.withLock { $0 != nil } }
        #expect(completed.withLock { $0 } == true)
    }

    @Test("a promise from an abandoned connection fails without downloading")
    func abandonedConnection() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv"] = [makeEntry("notes.txt")]
        let model = SFTPBrowserModel(host: "example.com", startDirectory: "/srv") { _ in fake }
        model.connect()
        await waitUntil("connected") { model.connectionState == .connected }
        defer { model.disconnect(); model.removeDragStaging(); SFTPRemoteDrag.end() }
        let item = model.dragItem(for: try #require(model.entries.first))
        model.disconnect()
        await #expect(throws: (any Error).self) { try await item.export() }
        #expect(fake.transferCalls.isEmpty)
    }
}

/// A bounded reproducer: the old branch reads this promised local URL;
/// a real SwiftUI promise would instead wait for an asynchronous download.
nonisolated private final class PromisedURLProbe: NSObject, NSPasteboardItemDataProvider {
    private let requestCount = Mutex(0)
    private let mainCount = Mutex(0)
    var requests: Int { requestCount.withLock { $0 } }
    var mainThreadRequests: Int { mainCount.withLock { $0 } }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestCount.withLock { $0 += 1 }
        if Thread.isMainThread { mainCount.withLock { $0 += 1 } }
        item.setString("file:///tmp/materialized-promise.txt", forType: type)
    }
}
