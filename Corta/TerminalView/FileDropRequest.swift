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
import Synchronization

/// Type negotiation never asks a provider to supply a URL or contents.
enum FileDropPolicy {
    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func accepts(types: [NSPasteboard.PasteboardType], isLocal: Bool) -> Bool {
        !isLocal && types.contains { registeredTypes.contains($0) }
    }
}

/// One drop, with a single absolute deadline and exactly one terminal result.
/// Initiation stays inside performDragOperation, as AppKit requires. No URL
/// reads, coordination or received-content inspection run on the main thread.
@MainActor
final class FileDropRequest {
    struct Result {
        let urls: [URL]
        let directory: URL?
        let failed: Bool
        let timedOut: Bool

        var notice: String? {
            if timedOut { return L10n.text("drop.timeout") }
            if failed { return L10n.text(urls.isEmpty ? "drop.failed" : "drop.partial") }
            return nil
        }
    }

    private var completion: ((Result) -> Void)?
    private var timer: Task<Void, Never>?
    private let collection: FileDropCollection
    private let queue = OperationQueue()

    init(count: Int, directory: URL?, timeout: Duration = .seconds(120),
         completion: @escaping (Result) -> Void) {
        collection = FileDropCollection(count: count, directory: directory)
        self.completion = completion
        queue.maxConcurrentOperationCount = 1
        timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout, clock: .suspending) } catch { return }
            self?.finish(timedOut: true)
        }
    }

    /// Snapshot types only. Promise takes precedence *per item*, so a lazy
    /// public.file-url on the same item is never called as a second export.
    static func start(
        _ pasteboard: NSPasteboard, receivers suppliedReceivers: [NSFilePromiseReceiver]? = nil,
        completion: @escaping (Result) -> Void
    ) -> FileDropRequest? {
        let items = pasteboard.pasteboardItems ?? []
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let supported = items.filter { item in
            item.types.contains(.fileURL) || item.types.contains { promiseTypes.contains($0) }
        }
        guard !supported.isEmpty else { return nil }
        let receivers = suppliedReceivers ?? ((pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver]) ?? [])
        let promised = supported.filter { item in item.types.contains { promiseTypes.contains($0) } }.count
        guard promised == receivers.count else { return nil }
        // A directory is created only for promises; direct file URLs remain
        // the user's originals and are never chmod'd or removed.
        let directory: URL?
        do { directory = promised > 0 ? try FileDropStorage.makeDirectory() : nil } catch { return nil }
        let request = FileDropRequest(count: supported.count, directory: directory, completion: completion)
        request.queue.isSuspended = true
        var receiverIndex = 0
        for (index, item) in supported.enumerated() {
            if item.types.contains(where: { promiseTypes.contains($0) }), let directory {
                let receiver = receivers[receiverIndex]
                receiverIndex += 1
                request.receive(receiver,
                    at: FileDropStorage.destination(in: directory), index: index)
            } else {
                request.readURL(FileDropURLItem(item), index: index)
            }
        }
        request.seal()
        return request
    }

    func receive(_ receiver: NSFilePromiseReceiver, at directory: URL, index: Int) {
        let collection = collection
        receiver.receivePromisedFiles(
            atDestination: directory, options: [:], operationQueue: queue
        ) { @Sendable url, error in
            do {
                guard error == nil else { throw CocoaError(.fileReadUnknown) }
                try FileDropStorage.secureReceived(url, in: directory)
                collection.record(url, index: index)
            } catch {
                collection.record(nil, index: index)
            }
        }
    }

    private func readURL(_ item: FileDropURLItem, index: Int) {
        let collection = collection
        queue.addOperation { collection.record(item.read(), index: index) }
    }

    /// The queue's drain is the boundary, not fileTypes/fileNames counts or
    /// a quiet-period heuristic. A receiver may schedule multiple readers.
    func seal() {
        queue.addBarrierBlock { [weak self] in
            Task { @MainActor [weak self] in self?.finish(timedOut: false) }
        }
        queue.isSuspended = false
    }

    private func finish(timedOut: Bool) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel()
        timer = nil
        if timedOut { queue.cancelAllOperations() }
        let result = collection.finish(timedOut: timedOut)
        completion(result)
    }

    func cancel() {
        completion = nil
        timer?.cancel()
        timer = nil
        queue.cancelAllOperations()
        collection.discard()
    }
}

/// Ownership transfers to one worker; AppKit's pasteboard item is read only
/// there, once. It is never revisited on the main actor after capture.
nonisolated private final class FileDropURLItem: @unchecked Sendable {
    private let item: NSPasteboardItem
    init(_ item: NSPasteboardItem) { self.item = item }
    func read() -> URL? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL
        else { return nil }
        return url
    }
}

/// All callback and deadline races meet under this lock. Late callbacks do
/// not retain UI state or publish paths and remove abandoned staging again.
nonisolated final class FileDropCollection: Sendable {
    private struct State {
        var urls: [[URL]]
        var seen: Set<Int> = []
        var failed = false
        var finished = false
        var published = false
    }
    private let state: Mutex<State>
    let directory: URL?

    init(count: Int, directory: URL?) {
        state = Mutex(State(urls: Array(repeating: [], count: count)))
        self.directory = directory
    }

    func record(_ url: URL?, index: Int) {
        let remove = state.withLock { state in
            guard !state.finished else { return !state.published }
            state.seen.insert(index)
            if let url { state.urls[index].append(url) } else { state.failed = true }
            return false
        }
        if remove { FileDropStorage.remove(directory) }
    }

    @MainActor func finish(timedOut: Bool) -> FileDropRequest.Result {
        state.withLock { state in
            state.finished = true
            let urls = state.urls.flatMap { $0 }
            state.published = !urls.isEmpty
            let result = FileDropRequest.Result(urls: urls, directory: directory,
                failed: state.failed || state.seen.count != state.urls.count, timedOut: timedOut)
            state.urls.removeAll()
            state.seen.removeAll()
            if urls.isEmpty { FileDropStorage.remove(directory) }
            return result
        }
    }

    func discard() {
        state.withLock { state in
            state.finished = true
            state.published = false
            state.urls.removeAll()
            state.seen.removeAll()
        }
        FileDropStorage.remove(directory)
    }
}
