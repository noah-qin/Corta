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
    static func write(_ text: String, to url: URL, shouldCommit: () -> Bool = { true }) throws {
        let target = resolvingLinks(url)
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The kept mode from the first byte: an `.atomic` write at the umask
        // and a `chmod` after left a `0600` rc file holding exported tokens
        // world-readable in between, and for good if the `chmod` failed.
        let mode = mode_t((permissions ?? 0o600) & 0o777)
        try PrivateFile.replace(at: target, with: Data(text.utf8), shouldCommit: shouldCommit) { descriptor in
            fchmod(descriptor, mode) == 0 ? 0 : errno
        }
    }

    /// What reading a user's text file found. `unreadable` — permissions, or
    /// bytes that are not UTF-8 — is never the same as `missing`: a caller
    /// that wrote "defaults" or "just our block" over such a file erased it.
    enum ReadResult: Sendable {
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

    static func readTextBounded(at url: URL) -> ReadResult {
        PathProbe.answer(timeout: .seconds(1)) { readText(at: url) } ?? .unreadable(POSIXError(.ETIMEDOUT))
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
/// directory history, window state — and exported terminal text. Owner-only
/// from the first byte: written at the default umask and `chmod`ed after,
/// each was readable by others for a moment, and stayed so if the second
/// step never ran.
nonisolated enum PrivateFile {
    /// Atomic: a `0600` temporary beside `url`, stripped of any ACL the
    /// folder hands down before a byte is written, renamed over it.
    static func write(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        try replace(at: url, with: data) { makeOwnerOnly(descriptor: $0) }
    }

    /// What the file holds, its permissions tightened first: one left by an
    /// older build or a restored backup stays as it came until the next save.
    /// Hardening, not a boundary: `~/Library` already keeps other accounts out.
    /// Nothing is followed: a link here is no file of Corta's.
    static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EINVAL)
        }
        _ = makeOwnerOnly(descriptor: descriptor)
        return try handle.readToEnd() ?? Data()
    }

    /// A missing file is a normal empty store. An unanswered or unreadable
    /// file is different: the caller must not replace its unseen contents.
    static func readBounded(_ url: URL) throws -> Data? {
        guard let result = PathProbe.answer(timeout: .seconds(1), { Result { try read(url) } }) else {
            throw POSIXError(.ETIMEDOUT)
        }
        do {
            return try result.get()
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    static func removeIfPresent(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Owner-only, with the parents it needs: at the default umask a state
    /// directory lists what it holds to anyone who can reach it.
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The temporaries `replace` leaves when it dies between its write and
    /// rename: a copy of a state file, which Clear History does not reach.
    /// Nothing younger than `olderThan`, which may be another Corta's, mid-save.
    static func removeAbandonedTemporaries(in directory: URL, olderThan age: TimeInterval, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isTemporaryName(name) {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > age
            else { continue }
            unlink(path)
        }
    }

    /// `.<name>.<uuid>`, as `replace` makes them, and nothing else that starts
    /// with a dot.
    static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix("."), let dot = name.lastIndex(of: "."), dot != name.startIndex,
            name[name.index(after: name.startIndex)..<dot].isEmpty == false
        else { return false }
        return UUID(uuidString: String(name[name.index(after: dot)...])) != nil
    }

    /// A temporary beside `url`, created `0600`, given its final permissions
    /// by `prepare` (0 or an `errno`) before a byte is written, renamed over
    /// `url`.
    static func replace(
        at url: URL, with data: Data, shouldCommit: () -> Bool = { true }, prepare: (Int32) -> Int32
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try writeExclusively(data, at: temporary, prepare: prepare)
        do {
            guard shouldCommit() else { throw POSIXError(.ECANCELED) }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        // The rename already committed. Report failures only before that
        // point, so a caller never rolls back memory after changing disk.
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
    }

    /// Writes at a path that must not exist, with final permissions set before the first byte.
    static func writeExclusively(
        _ data: Data, at url: URL, prepare: (Int32) -> Int32 = { makeOwnerOnly(descriptor: $0) }
    ) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let code = prepare(descriptor)
            guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(url.path)
            throw error
        }
    }
}
