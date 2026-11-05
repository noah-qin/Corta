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

/// What a destination reading the pasteboard during a hover may cost: nothing.
/// `RemoteWorkflowUITests` holds a real drag over Finder; these hold the
/// provider and the table's published row to the same rule without a window
/// server drag.
@MainActor
struct SFTPDragProviderTests {
    @Test("a row's provider names the file and starts nothing until a file is asked for")
    func nothingStartsUntilAsked() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("notes.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.disconnect(); model.removeDragStaging() }
        let provider = model.dragItem(for: try #require(model.entries.first)).itemProvider()
        #expect(provider.suggestedName == "notes.txt")
        #expect(provider.registeredTypeIdentifiers == [UTType.data.identifier])
        try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        #expect(fake.transferCalls.isEmpty)
    }

    /// `.draggable` published `public.file-url` too, answered by an export, so
    /// the read Finder makes while the pointer is over it downloaded the file,
    /// twice. Reading through a detached task fails on that rather than hangs.
    @Test("reading the table's published row during a hover downloads nothing")
    func hoverReadDownloadsNothing() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("notes.txt")]
        let model = await connectedModel(fake: fake)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SFTPBrowserView(model: model))
        window.orderFront(nil)
        defer { window.close(); model.disconnect(); model.removeDragStaging() }
        func listing(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { listing(in: $0) }.first
        }
        await waitUntil("the row is listed") {
            window.contentView.flatMap { listing(in: $0) }?.numberOfRows == 1
        }
        let outline = try #require(window.contentView.flatMap { listing(in: $0) })
        let row = try #require(outline.item(atRow: 0))
        let writer = try #require(outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: row))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([writer]))
        let promised = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let types = try #require(pasteboard.types)
        #expect(types.contains { promised.contains($0) }, "a file promise, which only a drop redeems")
        #expect(!types.contains(.fileURL), "a file URL would have to exist before anything is dropped")
        // What Finder's update timer does while the pointer is over it.
        let transfer = UncheckedPasteboard(pasteboard)
        let done = Mutex(false)
        Task.detached {
            _ = transfer.pasteboard.readObjects(forClasses: [NSURL.self, NSFilePromiseReceiver.self])
            done.withLock { $0 = true }
        }
        await waitUntil("the reads returned") { done.withLock { $0 } }
        try await Task.sleep(for: .milliseconds(100), clock: .suspending)
        #expect(fake.transferCalls.isEmpty)
        #expect(model.transfers.isEmpty)
    }

    @Test("asking for the file answers later, with the main actor free, from the folder it was picked up in")
    func fileArrivesAsynchronouslyFromItsOwnFolder() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("notes.txt")]
        let gate = AsyncStream<Void>.makeStream()
        fake.onTransfer = { call, _ in
            for await _ in gate.stream {}
            try Data("remote file".utf8).write(to: URL(fileURLWithPath: call.localPath))
        }
        let model = await connectedModel(fake: fake)
        defer { gate.continuation.finish(); model.disconnect(); model.removeDragStaging() }
        let provider = model.dragItem(for: try #require(model.entries.first)).itemProvider()
        model.navigate(to: "/other")
        await waitUntil("navigated") { !model.isLoading }
        let result = Mutex<Result<Data, any Error>?>(nil)
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
            result.withLock { value in
                value = Result {
                    if let error { throw error }
                    return try Data(contentsOf: #require(url))
                }
            }
        }
        // This suite runs on the main actor: reaching here at all means the
        // handler did not hold it for the download.
        await waitUntil("the download started") { !fake.transferCalls.isEmpty }
        #expect(fake.transferCalls.first?.remotePath == "/srv/app/notes.txt")
        #expect(result.withLock { $0 } == nil)
        #expect(model.transfers.count == 1, "the drop has a progress row like any download")
        gate.continuation.finish()
        await waitUntil("the file arrived") { result.withLock { $0 != nil } }
        #expect(try result.withLock { try $0?.get() } == Data("remote file".utf8))
    }

    @Test("a failed or cancelled download completes the provider", arguments: [false, true])
    func failureCompletesTheProvider(cancel: Bool) async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("notes.txt")]
        fake.onTransfer = { _, _ in
            if cancel { try await Task.sleep(for: .seconds(60)) }
            throw SFTPError.transport(.closed)
        }
        let model = await connectedModel(fake: fake)
        defer { model.disconnect(); model.removeDragStaging() }
        let provider = model.dragItem(for: try #require(model.entries.first)).itemProvider()
        let failed = Mutex<Bool?>(nil)
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
            failed.withLock { $0 = url == nil && error != nil }
        }
        await waitUntil("the download started") { !fake.transferCalls.isEmpty }
        if cancel { model.cancelTransfer(try #require(model.transfers.first).id) }
        await waitUntil("the provider answered") { failed.withLock { $0 != nil } }
        #expect(failed.withLock { $0 } == true)
    }

    @Test("a drag picked up on a connection that has ended downloads nothing")
    func endedConnectionDownloadsNothing() async throws {
        let fake = FakeSFTPClient()
        fake.listings["/srv/app"] = [makeEntry("notes.txt")]
        let model = await connectedModel(fake: fake)
        defer { model.removeDragStaging() }
        let item = model.dragItem(for: try #require(model.entries.first))
        model.disconnect()
        await #expect(throws: (any Error).self) { try await item.export() }
        #expect(fake.transferCalls.isEmpty)
    }
}

nonisolated private struct UncheckedPasteboard: @unchecked Sendable {
    let pasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
}
