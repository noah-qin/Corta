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

/// Local files dragged in from outside Corta — Finder, Photos, Mail, a
/// browser — never the SFTP browser's own row (`SFTPRemoteDrag`).
///
/// A `file-url` on an item that advertises no file promise is resident data
/// and is read at once. An item that advertises a promise
/// (`NSFilePromiseReceiver.readableDraggedTypes`) is a file its source will
/// write when asked; a URL beside it is a placeholder — an iCloud item not
/// yet downloaded, a photo not yet exported — and reading it while the drag
/// is tracked makes the source write synchronously on a queue that needs the
/// same main actor. Tracking therefore answers "can drop" from the types
/// alone. After the drop the promise is received through the public
/// `NSFilePromiseReceiver` API into a folder of this launch's temporary
/// directory, and the written paths arrive on the main actor. Nothing private
/// is queried.
@MainActor
enum ExternalFileDrop {
    /// File URLs that are resident data: items carrying no file promise.
    static func residentPaths(on pasteboard: NSPasteboard) -> [String] {
        if SFTPRemoteDrag.matchesRecordedLink(pasteboard) { return [] }
        let items = pasteboard.pasteboardItems ?? []
        if items.isEmpty {
            guard pasteboard.types?.contains(.fileURL) == true, let text = pasteboard.string(forType: .fileURL)
            else { return [] }
            return [path(fromFileURLText: text)].compactMap { $0 }
        }
        return items.filter { $0.types.contains(.fileURL) && !isPromise($0) }
            .compactMap { $0.string(forType: .fileURL).flatMap(path(fromFileURLText:)) }
    }

    /// A file promise from another application: droppable, received later.
    static func hasExternalPromise(on pasteboard: NSPasteboard) -> Bool {
        SFTPRemoteDrag.isFilePromise(pasteboard.types ?? []) && !SFTPRemoteDrag.matchesRecordedLink(pasteboard)
    }

    /// How many files are promised, for a drop overlay's count: one per
    /// promised content type, which is pasteboard metadata (a promise's
    /// names are not known until it is received). No file is asked for.
    static func promisedFileCount(on pasteboard: NSPasteboard) -> Int {
        guard hasExternalPromise(on: pasteboard) else { return 0 }
        // A promise type without receiver metadata still promises something.
        return max(receivers(on: pasteboard).reduce(0) { $0 + Self.fileCount(of: $1) }, 1)
    }

    private static func fileCount(of receiver: NSFilePromiseReceiver) -> Int {
        max(receiver.fileTypes.count, receiver.fileNames.count, 1)
    }

    /// Receives every promised file into a new folder under the temporary
    /// directory and delivers the written paths on the main actor, in the
    /// order they finished. A file the source failed to write is left out;
    /// `completion` gets an empty list when nothing arrived. AppKit allows
    /// this only inside `performDragOperation` (or its prepare/conclude
    /// neighbours), so only a drop calls it — never tracking, never a test
    /// without a drag session.
    static func receivePromisedFiles(
        on pasteboard: NSPasteboard, completion: @escaping @MainActor ([String]) -> Void
    ) {
        let receivers = receivers(on: pasteboard)
        let expected = receivers.reduce(0) { $0 + Self.fileCount(of: $1) }
        guard expected > 0, let destination = makeStagingFolder() else {
            completion([])
            return
        }
        let collector = PromiseCollector(expected: expected, completion: completion)
        let queue = OperationQueue()
        queue.name = "dev.noahqin.Corta.dropped-files"
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination, options: [:], operationQueue: queue
            ) { url, error in
                collector.received(error == nil ? url.path : nil)
            }
        }
    }

    private static func isPromise(_ item: NSPasteboardItem) -> Bool {
        item.types.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) }
    }

    private static func receivers(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
    }

    /// `$TMPDIR/Corta-Dropped/<UUID>/`, owner-only. The system purges its
    /// temporary folder; the path typed into the shell is this copy's.
    private static func makeStagingFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Corta-Dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return folder
        } catch {
            return nil
        }
    }

    private static func path(fromFileURLText text: String) -> String? {
        guard let url = URL(string: text), url.isFileURL else { return nil }
        return url.path
    }
}

/// Counts the reader's calls off the main actor; completes once on it.
private nonisolated final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var paths: [String] = []
    private let completion: @MainActor ([String]) -> Void

    init(expected: Int, completion: @escaping @MainActor ([String]) -> Void) {
        remaining = expected
        self.completion = completion
    }

    func received(_ path: String?) {
        lock.lock()
        if let path { paths.append(path) }
        remaining -= 1
        let done = remaining == 0
        let result = paths
        lock.unlock()
        guard done else { return }
        let completion = completion
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
    }
}
