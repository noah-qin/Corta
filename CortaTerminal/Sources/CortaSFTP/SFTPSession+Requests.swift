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

import Darwin
import Foundation

extension SFTPSession {
    // MARK: - Requests

    /// OPEN (§8.1.1). `attributes` applies only when creating.
    public func open(
        path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = .init()
    ) async throws(SFTPError) -> SFTPHandle {
        let reply = try await request { _ in
            .open(path: Array(path.utf8), flags: flags, attributes: attributes)
        }
        guard case .handle(let handle) = reply.payload else {
            throw unexpected(reply, wanted: "HANDLE")
        }
        return SFTPHandle(rawValue: handle)
    }

    /// OPENDIR (§8.1.2).
    public func openDirectory(path: String) async throws(SFTPError) -> SFTPHandle {
        let reply = try await request { _ in .opendir(path: Array(path.utf8)) }
        guard case .handle(let handle) = reply.payload else {
            throw unexpected(reply, wanted: "HANDLE")
        }
        return SFTPHandle(rawValue: handle)
    }

    /// CLOSE (§8.1.3). Always safe to call on a handle the server may
    /// already have dropped: its STATUS is the answer, and a stale handle
    /// simply gets a failure STATUS back.
    public func close(_ handle: SFTPHandle) async throws(SFTPError) {
        try expectOK(await request { _ in .close(handle: handle.rawValue) })
    }

    /// READ (§8.2.1). Returns the bytes read; fewer than `length` at end
    /// of file, and an empty array when the server answered EOF outright,
    /// so a caller's loop ends on `data.isEmpty` rather than on a thrown
    /// status.
    public func read(
        handle: SFTPHandle, offset: UInt64, length: UInt32
    ) async throws(SFTPError) -> [UInt8] {
        let reply = try await request { _ in
            .read(handle: handle.rawValue, offset: offset, length: length)
        }
        switch reply.payload {
        case .data(let data):
            return data
        case .status(let status) where status.code == .endOfFile:
            return []
        default:
            throw unexpected(reply, wanted: "DATA")
        }
    }

    /// WRITE (§8.2.2).
    public func write(
        handle: SFTPHandle, offset: UInt64, data: [UInt8]
    ) async throws(SFTPError) {
        try expectOK(await request { _ in .write(handle: handle.rawValue, offset: offset, data: data) })
    }

    /// STAT (§8.3): follows symbolic links.
    public func stat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await attributesRequest { _ in .stat(path: Array(path.utf8)) }
    }

    /// LSTAT (§8.3): does not follow symbolic links.
    public func lstat(path: String) async throws(SFTPError) -> SFTPAttributes {
        try await attributesRequest { _ in .lstat(path: Array(path.utf8)) }
    }

    /// SETSTAT (§8.4).
    public func setStat(path: String, attributes: SFTPAttributes) async throws(SFTPError) {
        try expectOK(await request { _ in .setstat(path: Array(path.utf8), attributes: attributes) })
    }

    /// FSETSTAT (§8.4) on an open handle.
    public func fsetStat(handle: SFTPHandle, attributes: SFTPAttributes) async throws(SFTPError) {
        try expectOK(await request { _ in .fsetstat(handle: handle.rawValue, attributes: attributes) })
    }

    /// MKDIR (§8.5).
    public func makeDirectory(path: String, attributes: SFTPAttributes = .init()) async throws(SFTPError) {
        try expectOK(await request { _ in .mkdir(path: Array(path.utf8), attributes: attributes) })
    }

    /// RMDIR (§8.6).
    public func removeDirectory(path: String) async throws(SFTPError) {
        try expectOK(await request { _ in .rmdir(path: Array(path.utf8)) })
    }

    /// REMOVE (§8.7) — a file, never a directory.
    public func remove(path: String) async throws(SFTPError) {
        try expectOK(await request { _ in .remove(path: Array(path.utf8)) })
    }

    /// RENAME (§8.8). Version 3 semantics: fails when the destination
    /// exists. For atomic overwrite use `posixRename(from:to:)`.
    public func rename(from oldPath: String, to newPath: String) async throws(SFTPError) {
        try expectOK(await request { _ in
            .rename(oldPath: Array(oldPath.utf8), newPath: Array(newPath.utf8))
        })
    }

    /// `posix-rename@openssh.com`: RENAME that overwrites an existing
    /// destination atomically. Returns false — rather than throwing — when
    /// the server never advertised the extension, so the caller can fall
    /// back explicitly; a refusal from a server that *did* advertise it is
    /// a real error and throws.
    @discardableResult
    public func posixRename(from oldPath: String, to newPath: String) async throws(SFTPError) -> Bool {
        guard capabilities?.supportsPosixRename == true else { return false }
        var writer = SFTPWriter()
        writer.writeString(Array(oldPath.utf8))
        writer.writeString(Array(newPath.utf8))
        do {
            let reply = try await extended(
                name: SFTPCodec.posixRenameExtensionName, data: writer.bytes)
            try expectOK(reply)
            return true
        } catch SFTPError.server(let status) where status.code == .operationUnsupported {
            return false
        }
    }

    /// REALPATH (§8.9). Returns the canonical path as raw bytes.
    public func realPath(path: String) async throws(SFTPError) -> [UInt8] {
        let reply = try await request { _ in .realpath(path: Array(path.utf8)) }
        guard case .name(let entries) = reply.payload, let first = entries.first else {
            throw unexpected(reply, wanted: "NAME with one entry")
        }
        return first.filename
    }

    /// One READDIR batch (§8.2.3). The server parcels a directory into as
    /// many batches as it likes; an empty array means the server answered
    /// EOF — the listing is complete. Loop until empty for the whole
    /// directory (`SFTPTransferEngine.listDirectory` does).
    public func readDirectory(handle: SFTPHandle) async throws(SFTPError) -> [SFTPEntry] {
        let reply = try await request { _ in .readdir(handle: handle.rawValue) }
        switch reply.payload {
        case .name(let entries):
            return entries
        case .status(let status) where status.code == .endOfFile:
            return []
        default:
            throw unexpected(reply, wanted: "NAME")
        }
    }

    /// A raw EXTENDED round trip (§10): `name` selects the extension and
    /// `data` is its request body. The reply body is returned uninterpreted.
    public func extended(name: String, data: [UInt8]) async throws(SFTPError) -> SFTPMessage {
        try await request { _ in .extended(name: Array(name.utf8), data: data) }
    }

    /// `statvfs@openssh.com`: filesystem capacity for the filesystem
    /// containing `path`. `nil` — explicitly, never guessed — when the
    /// server does not support the extension, whether because its VERSION
    /// did not advertise it or because it answered OP_UNSUPPORTED.
    public func volumeInfo(path: String = "/") async throws(SFTPError) -> SFTPVolumeInfo? {
        guard capabilities?.supportsStatVFS == true else { return nil }
        var writer = SFTPWriter()
        writer.writeString(Array(path.utf8))
        do {
            let reply = try await extended(name: SFTPCodec.statVFSExtensionName, data: writer.bytes)
            guard case .extendedReply(let body) = reply.payload else {
                throw unexpected(reply, wanted: "EXTENDED_REPLY")
            }
            guard let info = SFTPVolumeInfo(extendedReplyBody: body) else {
                throw SFTPError.protocolViolation("malformed statvfs reply (\(body.count) bytes)")
            }
            return info
        } catch SFTPError.server(let status) where status.code == .operationUnsupported {
            // Advertised but refused: degrade all the same.
            return nil
        } catch let error as SFTPError {
            throw error
        } catch {
            throw SFTPError.protocolViolation("\(error)")
        }
    }
}
