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

/// Owned promise copies. Published pane paths have no safe automatic expiry:
/// a program may open them long after the pane or app closes. Only the user
/// removes those; abandoned receptions and browser-owned uploads are removed.
nonisolated enum FileDropStorage {
    static var root: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("DroppedFiles", isDirectory: true)
    }

    static func makeDirectory(in root: URL = root) throws -> URL {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // A staged launch may use /tmp or another symlinked parent. Give
        // providers the canonical parent, while still refusing a symlink at
        // the private root itself.
        let root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        try secureDirectory(root)
        DispatchQueue.global(qos: .utility).async { pruneAbandoned(in: root) }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try secureDirectory(directory)
        do {
            try secureDirectory(destination(in: directory))
            try PrivateFile.write(Data(String(getpid()).utf8), to: directory.appendingPathComponent(".owner"))
        } catch {
            remove(directory)
            throw error
        }
        return directory
    }

    /// Provider-written names cannot collide with our ownership/publication
    /// records: those live one level above the shared receiver destination.
    static func destination(in directory: URL) -> URL {
        directory.appendingPathComponent("files", isDirectory: true)
    }

    /// Publication is durable before any path reaches a pane. Published
    /// directories are never expired by age, window closure or process exit.
    static func markPublished(_ directory: URL) throws {
        try PrivateFile.write(Data(), to: directory.appendingPathComponent(".published"))
    }

    /// A crashed receiver cannot publish more paths. Bounded maintenance
    /// removes its pending directories on the next promise reception; PID
    /// reuse conservatively keeps a directory rather than deleting live work.
    static func pruneAbandoned(in root: URL) {
        let children = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)) ?? []
        for directory in children.prefix(32) {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".published").path),
                let data = try? Data(contentsOf: directory.appendingPathComponent(".owner")),
                let pid = Int32(String(decoding: data, as: UTF8.self)), pid > 0,
                kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            remove(directory)
        }
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
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(descriptor) }
            guard makeOwnerOnly(descriptor: descriptor) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        default: throw CocoaError(.fileReadNoPermission)
        }
    }

    static func remove(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
