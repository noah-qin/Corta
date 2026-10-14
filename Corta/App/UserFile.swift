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

import Foundation

/// Writes a user-owned file (rc file, config) without changing what the
/// path is. `String.write(to:atomically:)` replaces a symlink with a plain
/// file — a dotfiles `~/.zshrc` stops being the repository's — and resets
/// permissions. This follows the link, writes atomically there, and
/// restores the permission bits.
nonisolated enum UserFile {
    /// Beyond this a chain counts as a loop and is written in place.
    private static let maximumLinkDepth = 32

    /// Writes atomically to the final target, creating its directory and
    /// keeping permissions. A dangling link's target is created, and the link
    /// stays.
    static func write(_ text: String, to url: URL) throws {
        let target = resolvingLinks(url)
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// What reading a user's text file found. `unreadable` — permissions, or
    /// bytes that are not UTF-8 — is never the same as `missing`: a caller
    /// that wrote "defaults" or "just our block" over such a file erased it.
    enum ReadResult {
        case missing
        case unreadable(any Error)
        case text(String)
    }

    /// Reads `url` as UTF-8, telling a missing file from one that exists but
    /// cannot be read or decoded.
    static func readText(at url: URL) -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
                || underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
            {
                // A dangling symlink is missing too: writing creates its target.
                return .missing
            }
            return .unreadable(error)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable(CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                NSFilePathErrorKey: url.path,
            ]))
        }
        return .text(text)
    }

    /// Follows links, resolving relative targets against the link's
    /// directory; unlike `resolvingSymlinksInPath()` it follows a link to a
    /// missing file.
    static func resolvingLinks(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        let manager = FileManager.default
        for _ in 0..<maximumLinkDepth {
            guard let attributes = try? manager.attributesOfItem(atPath: current.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                let destination = try? manager.destinationOfSymbolicLink(atPath: current.path)
            else { return current }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                current = current.deletingLastPathComponent()
                    .appendingPathComponent(destination).standardizedFileURL
            }
        }
        return current
    }
}

/// Corta's own state files that say where the user works — recent hosts,
/// directory history, window state. Owner-only from the first byte: written
/// at the default umask and `chmod`ed after, each was readable by others for
/// a moment, and stayed so if the second step never ran.
nonisolated enum PrivateFile {
    /// Atomic: a `0600` temporary beside `url`, renamed over it.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}
