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

/// The typed failure surface of the SFTP engine. Every layer below
/// the app reports through this one type, so a caller's `catch` never has
/// to guess which layer spoke.
public enum SFTPError: Error, Equatable {
    /// The server answered with a STATUS that was not `SSH_FX_OK` — a
    /// definitive answer to the request. Never retried: asking again gets
    /// the same answer.
    case server(SFTPStatus)
    /// The channel itself broke: the ssh subprocess died, a pipe failed,
    /// or the channel was closed. The only class the transfer engine
    /// retries, and only against a fresh channel.
    case transport(SFTPTransportError)
    /// The peer sent bytes that are not SFTPv3: an undecodable frame, a
    /// reply to a request-id nothing sent, or a wrong-shaped response.
    /// Also used when peer data exceeds an aggregate resource limit.
    case protocolViolation(String)
    /// The caller cancelled; in-flight requests were abandoned and the
    /// server was told nothing more.
    case cancelled
    /// The transfer engine found the destination already present under a
    /// `.fail` conflict policy.
    case destinationConflict(path: String)
    /// A local filesystem operation failed while staging a transfer.
    case localIOFailed(operation: String, code: Int32)
    /// The source changed while it was being read — it shrank, grew, was
    /// rewritten or replaced — so what arrived is none of its versions.
    /// Nothing was committed; the destination is as it was.
    case sourceChanged(path: String)
    /// Replacing the destination on a server without `posix-rename` failed
    /// half-way, and putting the old file back failed too. Nothing is lost,
    /// but the copies are apart: the old content is at `previousCopy`, the
    /// new at `newCopy`, and `destination` may hold neither.
    case replaceIncomplete(destination: String, previousCopy: String, newCopy: String)

    /// Whether a retry against a fresh channel could plausibly succeed.
    /// Transport failures only — a server STATUS is a considered answer,
    /// and a protocol violation means the peer is not speaking the
    /// protocol at all.
    public var isRetryableTransportFailure: Bool {
        if case .transport = self { return true }
        return false
    }

    /// Whether this is `.replaceIncomplete`: the one failure after which
    /// the partial must stay, because it may hold the only new copy.
    var isIncompleteReplacement: Bool {
        if case .replaceIncomplete = self { return true }
        return false
    }

    /// A STATUS of plain `SSH_FX_FAILURE` — what OpenSSH answers for an
    /// exclusive create of a name that exists.
    var isPlainServerFailure: Bool {
        if case .server(let status) = self { return status.code == .failure }
        return false
    }
}

extension SFTPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .server(let status):
            "the server answered \(status.code.rawValue): \(status.messageString)"
        case .transport(let error): "the channel failed: \(error)"
        case .protocolViolation(let detail): "protocol violation: \(detail)"
        case .cancelled: "cancelled"
        case .destinationConflict(let path): "the destination already exists: \(path)"
        case .localIOFailed(let operation, let code):
            "local \(operation) failed: errno \(code)"
        case .sourceChanged(let path): "the source changed during the transfer: \(path)"
        case .replaceIncomplete(let destination, let previousCopy, let newCopy):
            "replacing \(destination) did not finish: the old file is at \(previousCopy), the new one at \(newCopy)"
        }
    }
}

/// An open file or directory on the server. An opaque byte string by
/// protocol (§6.1: "the handle is a string... not interpreted by the
/// client"); equality is all the engine needs of it.
public struct SFTPHandle: Equatable, Sendable {
    public var rawValue: [UInt8]

    public init(rawValue: [UInt8]) {
        self.rawValue = rawValue
    }
}

/// What the server's VERSION told us, reduced to the capabilities the
/// engine acts on. Extensions the engine does not understand are kept
/// verbatim in `extensions` for the app to display.
public struct SFTPServerCapabilities: Equatable, Sendable {
    /// The protocol version the server answered INIT with.
    public var version: UInt32
    /// Extension name → data, as advertised.
    public var extensions: [String: [UInt8]]
    /// `statvfs@openssh.com` — filesystem capacity queries. When false,
    /// volume information is *unavailable*, not zero.
    public var supportsStatVFS: Bool
    /// `posix-rename@openssh.com` — rename that overwrites atomically.
    /// When false, version 3's plain RENAME fails against an existing
    /// destination and the transfer engine falls back to a documented
    /// non-atomic REMOVE+RENAME.
    public var supportsPosixRename: Bool

    public init(
        version: UInt32,
        extensions: [String: [UInt8]],
        supportsStatVFS: Bool,
        supportsPosixRename: Bool
    ) {
        self.version = version
        self.extensions = extensions
        self.supportsStatVFS = supportsStatVFS
        self.supportsPosixRename = supportsPosixRename
    }
}

/// The answer to `statvfs@openssh.com` (OpenSSH's `sftp-server` man page):
/// eleven `uint64` fields in the order of `struct statvfs`.
public struct SFTPVolumeInfo: Equatable, Sendable {
    public var blockSize: UInt64
    public var fragmentSize: UInt64
    public var blocks: UInt64
    public var blocksFree: UInt64
    public var blocksAvailable: UInt64
    public var files: UInt64
    public var filesFree: UInt64
    public var filesAvailable: UInt64
    public var filesystemID: UInt64
    public var flags: UInt64
    public var nameMaximum: UInt64

    public init(
        blockSize: UInt64, fragmentSize: UInt64, blocks: UInt64, blocksFree: UInt64,
        blocksAvailable: UInt64, files: UInt64, filesFree: UInt64, filesAvailable: UInt64,
        filesystemID: UInt64, flags: UInt64, nameMaximum: UInt64
    ) {
        self.blockSize = blockSize
        self.fragmentSize = fragmentSize
        self.blocks = blocks
        self.blocksFree = blocksFree
        self.blocksAvailable = blocksAvailable
        self.files = files
        self.filesFree = filesFree
        self.filesAvailable = filesAvailable
        self.filesystemID = filesystemID
        self.flags = flags
        self.nameMaximum = nameMaximum
    }

    /// Decodes an EXTENDED_REPLY body. `nil` for any shape but eleven
    /// words — a short reply is the server and the extension disagreeing,
    /// which is unanswerable rather than partially true.
    public init?(extendedReplyBody bytes: [UInt8]) {
        var reader = SFTPReader(bytes: bytes)
        guard
            let blockSize = try? reader.readUInt64(),
            let fragmentSize = try? reader.readUInt64(),
            let blocks = try? reader.readUInt64(),
            let blocksFree = try? reader.readUInt64(),
            let blocksAvailable = try? reader.readUInt64(),
            let files = try? reader.readUInt64(),
            let filesFree = try? reader.readUInt64(),
            let filesAvailable = try? reader.readUInt64(),
            let filesystemID = try? reader.readUInt64(),
            let flags = try? reader.readUInt64(),
            let nameMaximum = try? reader.readUInt64(),
            !reader.hasRemaining
        else { return nil }
        self.init(
            blockSize: blockSize, fragmentSize: fragmentSize, blocks: blocks, blocksFree: blocksFree,
            blocksAvailable: blocksAvailable, files: files, filesFree: filesFree,
            filesAvailable: filesAvailable, filesystemID: filesystemID, flags: flags,
            nameMaximum: nameMaximum)
    }
}
