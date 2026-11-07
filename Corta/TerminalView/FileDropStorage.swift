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

import CortaPOSIX
import Foundation
import Synchronization

/// Corta's own temporary copies: promised files dropped on a pane or an SFTP
/// listing, and SFTP rows on their way out. Every copy has an owner, and goes
/// with it: a pane's when the pane closes, a browser's after its upload or when
/// it closes, all of an instance's when it quits, and whatever an earlier run
/// left when the next one launches. A user's own files are never in here: a
/// plain file URL is used where it is, and creates no directory.
///
/// The roots live under Application Support, so a release build, a development
/// build and a staged launch each manage their own (D22).
nonisolated enum FileDropStorage {
    static var root: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("DroppedFiles", isDirectory: true)
    }

    /// SFTP rows being dragged out, kept apart from what was dropped in.
    static var dragRoot: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("SFTPDragStaging", isDirectory: true)
    }

    /// Tells this run from an earlier process that had the same pid.
    private static let launchID = UUID().uuidString

    /// Directories something is still writing or reading, which Clean Now
    /// leaves alone: from creation until `release(_:)` or `remove(_:)`.
    private static let pinned = Mutex<Set<String>>([])

    /// Removals under way, so that a quit can wait for them for a moment.
    private static let removals = DispatchGroup()

    static func makeDirectory(in root: URL = root) throws -> URL {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // A staged launch may use /tmp or another symlinked parent. Give
        // providers the canonical parent, while still refusing a symlink at
        // the private root itself.
        let root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        try secureDirectory(root)
        excludeFromBackup(root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try secureDirectory(directory)
        do {
            try secureDirectory(destination(in: directory))
            let record = Data("\(getpid()) \(launchID)".utf8)
            try PrivateFile.write(record, to: directory.appendingPathComponent(".owner"))
        } catch {
            remove(directory)
            throw error
        }
        pinned.withLock { _ = $0.insert(directory.standardizedFileURL.path) }
        return directory
    }

    /// Provider-written names cannot collide with our ownership record: it
    /// lives one level above the shared receiver destination.
    static func destination(in directory: URL) -> URL {
        directory.appendingPathComponent("files", isDirectory: true)
    }

    /// Nothing is writing it now: a pane's copies, once handed out, are what
    /// Clean Now may remove, having said that paths in use stop working.
    static func release(_ directory: URL) {
        pinned.withLock { _ = $0.remove(directory.standardizedFileURL.path) }
    }

    // MARK: - Whose is it

    enum Owner: Equatable {
        /// This very run.
        case thisRun
        /// Another Corta, alive, using the same storage.
        case otherLive
        /// Nobody any more: crashed, force-quit, or an older version.
        case gone
    }

    /// A pid alone cannot tell this run from an earlier one with the same pid,
    /// so a record names both; an older version's names only the pid. A pid
    /// that another process has since taken reads as live and keeps the copy
    /// for one more launch, which errs the right way.
    static func owner(fromRecord record: String?) -> Owner {
        let fields = (record ?? "").split(separator: " ")
        guard let first = fields.first, let pid = Int32(first), pid > 0 else { return .gone }
        if pid == getpid() { return fields.count > 1 && fields[1] == launchID ? .thisRun : .gone }
        return kill(pid, 0) != 0 && errno == ESRCH ? .gone : .otherLive
    }

    private static func owner(of directory: URL) -> Owner {
        let descriptor = open(directory.appendingPathComponent(".owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .gone }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try? handle.read(upToCount: 128)
        return owner(fromRecord: data.flatMap { String(bytes: $0, encoding: .utf8) })
    }

    /// The children of a root that is really a private directory of ours. A
    /// symlink here is refused: what it points at is not ours to walk.
    private static func children(of root: URL) -> [URL] {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
        else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func excludeFromBackup(_ root: URL) {
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: - Cleaning up

    /// What earlier runs left. Run once, in the background, as the app starts;
    /// also what a crash, a force-quit or an older version's copies wait for.
    /// A directory still being made by a live sibling has no record for an
    /// instant, so a young one without a record is left for the next launch.
    static func pruneAbandoned(in root: URL) {
        if isDirectory(root) { excludeFromBackup(root) }
        for child in children(of: root) {
            if child.lastPathComponent.hasPrefix(".removing-") || !isDirectory(child) { remove(child); continue }
            if owner(of: child) == .gone, !isYoungAndUnrecorded(child) { remove(child) }
        }
    }

    private static func isYoungAndUnrecorded(_ directory: URL) -> Bool {
        var info = stat()
        guard lstat(directory.appendingPathComponent(".owner").path, &info) != 0, errno == ENOENT,
            lstat(directory.path, &info) == 0
        else { return false }
        return Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) < 60
    }

    /// Everything this launch has to tidy, called off the main thread.
    static func cleanUpAtLaunch() {
        pruneAbandoned(in: root)
        pruneAbandoned(in: dragRoot)
        removeLegacyDragStaging()
    }

    /// Before this storage, drags staged in a shared temporary folder, which a
    /// sibling on an older version may still be using: only what has sat a day.
    static func removeLegacyDragStaging(
        in directory: URL = FileManager.default.temporaryDirectory, now: Date = Date()
    ) {
        let legacy = directory.appendingPathComponent("Corta-SFTP-Drag", isDirectory: true)
        for child in children(of: legacy) {
            var info = stat()
            guard lstat(child.path, &info) == 0,
                now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > 24 * 3600
            else { continue }
            remove(child)
        }
        rmdir(legacy.path)
    }

    /// A quit: this run's copies, for at most `timeout`, so a slow disk cannot
    /// hold up the exit. Whatever is left goes at the next launch.
    static func removeThisRun(in roots: [URL]? = nil, timeout: TimeInterval = 1.5) {
        let directories = roots ?? [root, dragRoot]
        let done = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .userInitiated).async {
            for root in directories {
                for child in children(of: root)
                where child.lastPathComponent.hasPrefix(".removing-") || owner(of: child) == .thisRun {
                    remove(child, qos: .userInitiated)
                }
            }
            _ = removals.wait(timeout: deadline)
            done.signal()
        }
        _ = done.wait(timeout: deadline)
    }

    /// Clean Now: this run's finished copies and anything nobody owns. What is
    /// being received or uploaded stays, and so does a live sibling's.
    static func removeUnpinned(in roots: [URL]? = nil) {
        let held = pinned.withLock { $0 }
        for root in roots ?? [root, dragRoot] {
            for child in children(of: root) {
                if child.lastPathComponent.hasPrefix(".removing-") || !isDirectory(child) { remove(child); continue }
                if owner(of: child) != .otherLive, !held.contains(child.standardizedFileURL.path) { remove(child) }
            }
        }
    }

    /// Bytes on disk under the roots. Never follows a link; call off the main
    /// thread, since a copy can hold any number of files.
    static func usage(in roots: [URL]? = nil) -> Int64 {
        var total: Int64 = 0
        for root in roots ?? [root, dragRoot] where !children(of: root).isEmpty {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
            else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true
                else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func secureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), clearExtendedACL(path: url.path) == 0,
            chmod(url.path, 0o700) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// Refuse escaped paths and symlinks; tighten every descendant before it
    /// is handed to a consumer. The private root protects inherited contents.
    static func secureReceived(_ url: URL, in directory: URL) throws {
        let prefix = directory.standardizedFileURL.path + "/"
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(prefix),
            url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
        else { throw CocoaError(.fileReadNoPermission) }
        var remaining = 100_000
        try secureTree(url, depth: 0, remaining: &remaining)
    }

    private static func secureTree(_ url: URL, depth: Int, remaining: inout Int) throws {
        guard depth <= 128, remaining > 0 else { throw POSIXError(.EFBIG) }
        remaining -= 1
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard clearExtendedACL(path: url.path) == 0, chmod(url.path, 0o700) == 0
            else { throw CocoaError(.fileWriteNoPermission) }
            var enumerationError: (any Error)?
            guard let children = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw CocoaError(.fileReadUnknown) }
            for case let child as URL in children {
                try secureTree(child, depth: depth + 1, remaining: &remaining)
            }
            if let enumerationError { throw enumerationError }
        case S_IFREG:
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(descriptor) }
            // Mode and ACLs belong to the inode: tightening a hard link would
            // tighten the original it shares them with, wherever that lives.
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1
            else { throw CocoaError(.fileReadNoPermission) }
            guard makeOwnerOnly(descriptor: descriptor) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        default: throw CocoaError(.fileReadNoPermission)
        }
    }

    /// Gone from its path at once, deleted off the caller's thread: this runs
    /// on the main actor, and a promised folder can hold any number of files.
    /// A link is removed as a link; nothing it points at is touched.
    static func remove(_ url: URL?, qos: DispatchQoS.QoSClass = .utility) {
        guard let url else { return }
        release(url)
        let doomed = url.deletingLastPathComponent()
            .appendingPathComponent(".removing-" + UUID().uuidString)
        let target: URL
        if rename(url.path, doomed.path) == 0 {
            target = doomed
        } else if errno == ENOENT {
            return
        } else {
            target = url
        }
        removals.enter()
        DispatchQueue.global(qos: qos).async {
            try? FileManager.default.removeItem(at: target)
            removals.leave()
        }
    }
}
