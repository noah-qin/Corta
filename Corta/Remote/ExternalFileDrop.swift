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
import Darwin

/// Whether a pasteboard item's type is still a promise. The public readers
/// fulfill a promise synchronously, which deadlocks when that fulfillment
/// needs the main actor that is tracking the drag. One private query
/// distinguishes a resident file URL from that promise; if it disappears,
/// every file URL is treated as promised and is not read on the tracking call.
enum PasteboardPromise {
    private static let selector = NSSelectorFromString("_isPromisedType:")
    private static let isPromised: (@convention(c) (AnyObject, Selector, NSString) -> Bool)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AnyObject, Selector, NSString) -> Bool).self)
    }()

    static func isPromisedFileURL(_ item: NSPasteboardItem) -> Bool {
        isPromised(item, type: .fileURL)
    }

    static func isPromised(_ item: NSPasteboardItem, type: NSPasteboard.PasteboardType) -> Bool {
        guard item.types.contains(type), item.responds(to: selector), let isPromised else { return true }
        return isPromised(item, selector, type.rawValue as NSString)
    }
}

/// Local paths from a drag that is not the SFTP browser's own row.
///
/// A resident `file-url` is read immediately. A promised one is read only
/// after this call has returned, on another thread, and the path is used
/// the next time tracking asks. The tracking call itself never waits.
@MainActor
enum ExternalFileDrop {
    fileprivate nonisolated struct Key: Hashable, Sendable {
        var name: String
        var change: Int
    }

    /// Shared with the off-main read. A `Task` would stay on the main executor,
    /// which drag tracking does not drain, so the promise would never be read.
    private nonisolated static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: [String]] = [:]
    nonisolated(unsafe) private static var pending: Set<Key> = []

    static func paths(on pasteboard: NSPasteboard) -> [String] {
        if SFTPRemoteDrag.matchesRecordedLink(pasteboard) { return [] }
        let key = Key(name: pasteboard.name.rawValue, change: pasteboard.changeCount)
        if let cached = cachedPaths(for: key) { return cached }
        if let resident = residentFilePaths(on: pasteboard) {
            store(resident, for: key)
            return resident
        }
        guard markPending(key) else { return [] }
        // The timer fires after this call returns. The provider runs off the
        // main thread, so the tracking call itself never reads and never waits.
        schedulePromisedRead(name: pasteboard.name.rawValue, key: key)
        return []
    }

    private nonisolated static func cachedPaths(for key: Key) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private nonisolated static func markPending(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.insert(key).inserted
    }

    private nonisolated static func schedulePromisedRead(name: String, key: Key) {
        // A run-loop timer, not a main-actor task: drag tracking spins the
        // run loop and would never drain the main executor. The timer only
        // queues the read, after this call has returned.
        let reader = PromisedFileRead(name: name, key: key)
        Timer.scheduledTimer(
            timeInterval: 0.001, target: reader, selector: #selector(PromisedFileRead.fire),
            userInfo: nil, repeats: false)
    }

    fileprivate nonisolated static func finishPromisedRead(_ paths: [String], for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count > 32 { cache.removeAll() }
        cache[key] = paths
        pending.remove(key)
    }

    private nonisolated static func store(_ paths: [String], for key: Key) {
        finishPromisedRead(paths, for: key)
    }

    /// `nil` when a file URL is still promised. An empty array is a resident answer.
    private static func residentFilePaths(on pasteboard: NSPasteboard) -> [String]? {
        let items = (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }
        if items.isEmpty {
            guard pasteboard.types?.contains(.fileURL) == true, let text = pasteboard.string(forType: .fileURL)
            else { return [] }
            return [path(fromFileURLText: text)].compactMap { $0 }
        }
        if items.contains(where: PasteboardPromise.isPromisedFileURL) { return nil }
        return items.compactMap { item in item.string(forType: .fileURL).flatMap(path(fromFileURLText:)) }
    }

    fileprivate nonisolated static func readPromisedFilePaths(pasteboardName: String) -> [String] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.map(\.path)
    }

    private static func path(fromFileURLText text: String) -> String? {
        guard let url = URL(string: text), url.isFileURL else { return nil }
        return url.path
    }
}

/// ObjC entry so the read is not a main-actor job. The timer retains it.
private nonisolated final class PromisedFileRead: NSObject, @unchecked Sendable {
    let name: String
    let key: ExternalFileDrop.Key

    init(name: String, key: ExternalFileDrop.Key) {
        self.name = name
        self.key = key
    }

    /// Queued by the timer on the main run loop, then read off that thread.
    @objc func fire() {
        performSelector(inBackground: #selector(read), with: nil)
    }

    @objc func read() {
        let paths = ExternalFileDrop.readPromisedFilePaths(pasteboardName: name)
        ExternalFileDrop.finishPromisedRead(paths, for: key)
    }
}
