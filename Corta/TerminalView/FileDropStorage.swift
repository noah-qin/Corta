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

/// Received promise copies, in `$TMPDIR/Corta-Dropped/<pid>-<uuid>/`, private
/// to the user. A path handed to a pane stays good until a later launch's
/// `removeStale`: a program may open it long after the drop, and the system
/// purges its temporary folder anyway. Copies an SFTP upload has finished with
/// go at once. The owner's pid is in the name because a development build and
/// the installed app share `$TMPDIR` and run side by side (D22).
nonisolated enum FileDropStorage {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Corta-Dropped", isDirectory: true)
    }

    static func makeDirectory(in root: URL = root) throws -> URL {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // `$TMPDIR` reaches through /var's symlink. Give providers the
        // canonical parent, while still refusing a symlink at the root itself.
        let root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        try secureDirectory(root)
        let directory = root.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try secureDirectory(directory)
        do {
            try secureDirectory(destination(in: directory))
        } catch {
            remove(directory)
            throw error
        }
        return directory
    }

    /// Where a provider writes: a level below, so its names stay apart from the
    /// `.removing-` renames beside it.
    static func destination(in directory: URL) -> URL {
        directory.appendingPathComponent("files", isDirectory: true)
    }

    /// At launch, off the main thread: every reception whose owner has gone.
    /// A live owner keeps its copies, and a reused pid keeps them until a later
    /// launch. A name this code did not write is left alone.
    static func removeStale(in root: URL = root) {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
        else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            guard let pid = ownerPID(ofDirectoryNamed: name), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// The pid in `<pid>-<uuid>`, or nil for any other name.
    static func ownerPID(ofDirectoryNamed name: String) -> pid_t? {
        guard let dash = name.firstIndex(of: "-"), let pid = pid_t(name[..<dash]), pid > 0,
            UUID(uuidString: String(name[name.index(after: dash)...])) != nil
        else { return nil }
        return pid
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
        try secureTree(url)
    }

    private static func secureTree(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard clearExtendedACL(path: url.path) == 0, chmod(url.path, 0o700) == 0
            else { throw CocoaError(.fileWriteNoPermission) }
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try secureTree(child)
            }
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
    static func remove(_ url: URL?) {
        guard let url else { return }
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
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: target) }
    }
}
