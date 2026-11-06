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
import CortaTerminal
import Synchronization
import Testing

@testable import Corta

@MainActor
struct FileDropTests {
    @Test("drag negotiation accepts promises and never invokes a lazy URL provider")
    func negotiationDoesNotRead() {
        let provider = LazyDropProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.fileURL])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])
        let drag = DropDraggingInfo(pasteboard)
        let pane = TerminalView(frame: .zero)
        for _ in 0..<10 {
            #expect(pane.draggingEntered(drag) == .copy)
            #expect(pane.draggingUpdated(drag) == .copy)
        }
        #expect(provider.reads.withLock { $0 } == 0)
        for type in NSFilePromiseReceiver.readableDraggedTypes {
            #expect(FileDropPolicy.accepts(types: [NSPasteboard.PasteboardType(type)], isLocal: false))
            #expect(!FileDropPolicy.accepts(types: [NSPasteboard.PasteboardType(type)], isLocal: true))
        }
        drag.source = NSObject()
        #expect(pane.draggingEntered(drag).isEmpty)
        #expect(!pane.performDragOperation(drag))
        #expect(provider.reads.withLock { $0 } == 0)
        #expect(!FileDropPolicy.accepts(types: [.string], isLocal: false))
    }

    @Test("the SFTP hover target negotiates without fetching lazy URLs and refuses local drags")
    func sftpNegotiationDoesNotRead() async {
        let model = await connectedModel(fake: FakeSFTPClient())
        defer { model.disconnect() }
        let provider = LazyDropProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.fileURL])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])
        let drag = DropDraggingInfo(pasteboard)
        let view = SFTPDropTargetView(frame: .zero)
        view.model = model
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        drag.source = NSObject()
        #expect(view.draggingUpdated(drag).isEmpty)
        #expect(provider.reads.withLock { $0 } == 0)
    }

    @Test("a lazy URL is read once, off main, after acceptance")
    func lazyURLReadOnce() async throws {
        let provider = LazyDropProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.fileURL])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])
        var result: FileDropRequest.Result?
        let request = try #require(FileDropRequest.start(pasteboard) { result = $0 })
        await waitUntil("lazy drop received") { result != nil }
        #expect(result?.urls.map(\.path) == ["/tmp/lazy file"])
        #expect(provider.reads.withLock { $0 } == 1)
        #expect(!provider.readOnMain.withLock { $0 })
        withExtendedLifetime(request) {}
    }

    @Test("callbacks already queued beyond the reported file names are still collected")
    func multiplePromiseCallbacks() async throws {
        let directory = try FileDropStorage.makeDirectory(in: scratchRoot())
        defer { FileDropStorage.remove(directory.deletingLastPathComponent()) }
        var result: FileDropRequest.Result?
        let request = FileDropRequest(count: 2, directory: directory) { result = $0 }
        let first = TestPromiseReceiver(names: ["first", "second"])
        let last = TestPromiseReceiver(names: ["last"])
        request.receive(first, at: FileDropStorage.destination(in: directory), index: 0)
        request.receive(last, at: FileDropStorage.destination(in: directory), index: 1)
        request.seal()
        await waitUntil("all promise readers drained") { result != nil }
        #expect(result?.urls.map(\.lastPathComponent) == ["first", "second", "last"])
        #expect(result?.failed == false)
        #expect(first.receives.withLock { $0 } == 1)
        #expect(last.receives.withLock { $0 } == 1)
        withExtendedLifetime(request) {}
    }

    /// The order a real drag produced: names appear during the receive call,
    /// the queue drains at once, and each reader follows its provider's write.
    @Test("a reception waits for readers that arrive after the queue has drained")
    func readersArriveAfterDrain() async throws {
        let directory = try FileDropStorage.makeDirectory(in: scratchRoot())
        defer { FileDropStorage.remove(directory.deletingLastPathComponent()) }
        var result: FileDropRequest.Result?
        let request = FileDropRequest(count: 2, directory: directory) { result = $0 }
        let legacy = LatePromiseReceiver(names: ["a", "b", "c"])
        let single = LatePromiseReceiver(names: ["d"])
        let destination = FileDropStorage.destination(in: directory)
        request.receive(legacy, at: destination, index: 0)
        request.receive(single, at: destination, index: 1)
        request.seal()
        // Readers land out of order across receivers; none has arrived yet.
        try await Task.sleep(for: .milliseconds(100), clock: .suspending)
        #expect(result == nil)
        single.deliverAll()
        legacy.deliver("a")
        legacy.deliver("b")
        try await Task.sleep(for: .milliseconds(100), clock: .suspending)
        #expect(result == nil)
        legacy.deliver("c")
        await waitUntil("every reader arrived") { result != nil }
        #expect(result?.urls.map(\.lastPathComponent) == ["a", "b", "c", "d"])
        #expect(result?.failed == false)
        withExtendedLifetime(request) {}
    }

    @Test("a provider that never finishes ends at the deadline with what arrived")
    func missingReaderTimesOut() async throws {
        let directory = try FileDropStorage.makeDirectory(in: scratchRoot())
        defer { FileDropStorage.remove(directory.deletingLastPathComponent()) }
        var result: FileDropRequest.Result?
        let request = FileDropRequest(count: 1, directory: directory, timeout: .milliseconds(200)) { result = $0 }
        let receiver = LatePromiseReceiver(names: ["ready", "never"])
        request.receive(receiver, at: FileDropStorage.destination(in: directory), index: 0)
        request.seal()
        receiver.deliver("ready")
        await waitUntil("the deadline passed") { result != nil }
        #expect(result?.urls.map(\.lastPathComponent) == ["ready"])
        #expect(result?.timedOut == true)
        withExtendedLifetime(request) {}
    }

    @Test("an item advertising both promise and lazy URL exports once via promise only")
    func promisePrecedence() async throws {
        let provider = LazyDropProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.fileURL])
        let type = NSPasteboard.PasteboardType(NSFilePromiseReceiver.readableDraggedTypes[0])
        item.setString("promise metadata", forType: type)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([item])
        let receiver = TestPromiseReceiver(names: [".owner", ".published"])
        var result: FileDropRequest.Result?
        let request = try #require(FileDropRequest.start(pasteboard, receivers: [receiver]) { result = $0 })
        await waitUntil("promised item received") { result != nil }
        let received = try #require(result)
        defer { FileDropStorage.remove(received.directory) }
        #expect(received.urls.map(\.lastPathComponent) == [".owner", ".published"])
        #expect(try received.urls.map { try String(contentsOf: $0, encoding: .utf8) } == [".owner", ".published"])
        #expect(receiver.receives.withLock { $0 } == 1)
        #expect(provider.reads.withLock { $0 } == 0)
        withExtendedLifetime(request) {}
    }

    @Test("partial and total failures have visible notices; ordering follows items, not readiness")
    func failuresAndOrdering() {
        let collection = FileDropCollection(count: 3, directory: nil)
        collection.record(URL(fileURLWithPath: "/last"), index: 2)
        collection.record(nil, index: 1)
        collection.record(URL(fileURLWithPath: "/first"), index: 0)
        let result = collection.finish(timedOut: false)
        #expect(result.urls.map(\.path) == ["/first", "/last"])
        #expect(result.failed)
        #expect(result.notice == L10n.text("drop.partial"))
        let failed = FileDropCollection(count: 1, directory: nil).finish(timedOut: false)
        #expect(failed.urls.isEmpty)
        #expect(failed.notice == L10n.text("drop.failed"))
    }

    @Test("the absolute timeout releases completion, removes empty staging and ignores late readers")
    func timeoutAndLateCallbacks() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        var results: [FileDropRequest.Result] = []
        let request = FileDropRequest(count: 1, directory: directory, timeout: .milliseconds(20)) {
            results.append($0)
        }
        // No seal: models a provider which never completes its receive call.
        await waitUntil("drop timed out") { results.count == 1 }
        let result = try #require(results.first)
        #expect(result.timedOut)
        #expect(result.notice == L10n.text("drop.timeout"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        request.seal()
        await Task.yield()
        #expect(results.count == 1)
        let collection = FileDropCollection(count: 1, directory: directory)
        _ = collection.finish(timedOut: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        collection.record(directory.appendingPathComponent("late"), index: 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        request.cancel()
    }

    @Test("a pane that closes mid-reception removes what arrives late and fills nothing")
    func closedPaneDropsLateArrival() async throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let host = CommandsTestHost()
        var completed = false
        let request = FileDropRequest(count: 1, directory: directory) { _ in completed = true }
        host.commands.fileDropRequest = request
        let receiver = LatePromiseReceiver(names: ["late"])
        let destination = FileDropStorage.destination(in: directory)
        request.receive(receiver, at: destination, index: 0)
        request.seal()
        host.commands.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // The provider finishes anyway, into a folder made again for it.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        receiver.deliverAll()
        await waitUntil("the late copy is gone") { !FileManager.default.fileExists(atPath: directory.path) }
        #expect(!completed)
        #expect(host.commands.droppedCopies.isEmpty)
    }

    @Test("completed pane copies survive maintenance; discarded copies are removed")
    func retainedAndDiscardedCopies() throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("keep")
        try Data("contents".utf8).write(to: file)
        let collection = FileDropCollection(count: 1, directory: directory)
        collection.record(file, index: 0)
        let result = collection.finish(timedOut: false)
        #expect(result.urls == [file])
        FileDropStorage.pruneAbandoned(in: root)
        #expect(FileManager.default.fileExists(atPath: file.path))
        collection.discard()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

// MARK: - The drop's target

extension FileDropTests {
    @Test("session identity and foreground group must both match; missing context fails closed")
    func contextBinding() {
        let session = NSObject()
        let otherSession = NSObject()
        let original = FileDropInputContext(session: ObjectIdentifier(session), foregroundGroup: 123)
        #expect(original == FileDropInputContext(session: ObjectIdentifier(session), foregroundGroup: 123))
        #expect(original != FileDropInputContext(session: ObjectIdentifier(otherSession), foregroundGroup: 123))
        #expect(original != FileDropInputContext(session: ObjectIdentifier(session), foregroundGroup: 456))
        #expect(CommandsTestHost().commands.dropInputContext == nil)
        // This is the same validation gate used again after a paste-warning sheet.
        var discarded = false
        let host = CommandsTestHost()
        host.commands.insertAsPaste("must not send", validate: { false }, onDiscard: { discarded = true })
        #expect(discarded)
    }

    @Test("a changed session or process group discards a received copy instead of pasting",
           arguments: ["session", "foreground", "missing"])
    func changedTargetDiscardsCopy(change: String) throws {
        let root = scratchRoot()
        defer { FileDropStorage.remove(root) }
        let directory = try FileDropStorage.makeDirectory(in: root)
        let file = directory.appendingPathComponent("sentinel")
        try Data().write(to: file)
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
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(host.terminalView.toastLayer != nil)
        withExtendedLifetime(otherIdentity) {}
    }

    @Test("drop payloads use the existing paste encoder and never append Return")
    func noReturn() {
        let text = PaneCommands.quotedDropText(["/tmp/a b", "/tmp/$(touch nope)"])
        #expect(text == "'/tmp/a b' '/tmp/$(touch nope)'")
        for bracketed in [false, true] {
            let bytes = Paste.chunks(for: text, bracketedPasteEnabled: bracketed).flatMap { $0 }
            #expect(!bytes.contains(10))
            #expect(!bytes.contains(13))
        }
    }

    func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Corta-Drop-Test-" + UUID().uuidString)
    }
}

/// Stand-in for the operation stream AppKit schedules, not a window-server
/// drag. Deliberately advertises one type and zero names for multiple files.
nonisolated private final class TestPromiseReceiver: NSFilePromiseReceiver {
    let names: [String]
    let receives = Mutex(0)
    init(names: [String]) { self.names = names; super.init() }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        return nil
    }
    override var fileTypes: [String] { ["public.data"] }
    override var fileNames: [String] { [] }
    override func receivePromisedFiles(
        atDestination directory: URL, options: [AnyHashable: Any] = [:],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
    ) {
        receives.withLock { $0 += 1 }
        // Copy a non-Sendable AppKit callback into the queue's operation;
        // invocation is serialized there, exactly as the API contract says.
        let callback = DropTestReader(reader)
        for name in names {
            operationQueue.addOperation {
                let url = directory.appendingPathComponent(name)
                do {
                    try Data(name.utf8).write(to: url)
                    callback.read(url, nil)
                } catch { callback.read(url, error) }
            }
        }
    }
}

/// AppKit's real order: `fileNames` fills during the receive call, and a
/// reader reaches the queue only when the test says its file has been written.
nonisolated final class LatePromiseReceiver: NSFilePromiseReceiver, @unchecked Sendable {
    private struct Pending {
        var names: [String] = []
        var directory: URL?
        var queue: OperationQueue?
        var reader: DropTestReader?
    }
    private let promised: [String]
    private let pending = Mutex(Pending())
    init(names: [String]) { promised = names; super.init() }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        return nil
    }
    override var fileNames: [String] { pending.withLock { $0.names } }
    override func receivePromisedFiles(
        atDestination directory: URL, options: [AnyHashable: Any] = [:],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
    ) {
        let callback = DropTestReader(reader)
        pending.withLock {
            $0 = Pending(names: promised, directory: directory, queue: operationQueue, reader: callback)
        }
    }
    func deliverAll() { promised.forEach(deliver) }
    func deliver(_ name: String) {
        let (directory, queue, reader) = pending.withLock { ($0.directory, $0.queue, $0.reader) }
        guard let directory, let queue, let reader else { return }
        let url = directory.appendingPathComponent(name)
        queue.addOperation {
            try? Data(name.utf8).write(to: url)
            reader.read(url, nil)
        }
    }
}

nonisolated private final class DropTestReader: @unchecked Sendable {
    let read: (URL, (any Error)?) -> Void
    init(_ read: @escaping (URL, (any Error)?) -> Void) { self.read = read }
}

nonisolated private final class LazyDropProvider: NSObject, NSPasteboardItemDataProvider {
    let reads = Mutex(0)
    let readOnMain = Mutex(false)
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        reads.withLock { $0 += 1 }
        readOnMain.withLock { $0 = Thread.isMainThread }
        item.setString("file:///tmp/lazy%20file", forType: type)
    }
}

@MainActor
private final class DropDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var source: AnyObject?
    var draggingSource: Any? { source }
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
