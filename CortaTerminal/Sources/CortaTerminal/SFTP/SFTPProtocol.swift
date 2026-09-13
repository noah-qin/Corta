import Foundation

/// B14 — the SFTPv3 wire protocol (draft-ietf-secsh-filexfer-02), the
/// version every OpenSSH `sftp-server` speaks.
///
/// This file is a pure codec: value types plus the functions that encode
/// them to and decode them from wire bytes. It performs no I/O, holds no
/// state, and never traps on input — the bytes being decoded come from a
/// process on the far side of an ssh channel, i.e. from a network-adjacent
/// peer, and are treated with the same suspicion as the terminal parser's
/// input stream (`Parser.maxStringLength` is the precedent): every length
/// is bounded, every read is bounds-checked, and every failure is a typed
/// `SFTPCodecError`, never a crash.
///
/// Framing (§3 "General Packet Format"): each frame on the wire is
///
/// ```
/// uint32  length          — byte count of everything after this field
/// byte    type            — one of SSH_FXP_*
/// uint32  request-id      — present in every message except INIT/VERSION
/// ...     type-specific payload
/// ```
///
/// All integers are big-endian. Strings are `uint32 length` plus raw bytes
/// — path names are *not* decoded as UTF-8 on the way in, because nothing
/// in the protocol guarantees an encoding; the raw bytes are preserved and
/// a lossy UTF-8 view is offered for display (`SFTPEntry.filenameUTF8`).
public enum SFTPCodec {
    /// The protocol version this client speaks. Version 3 is what OpenSSH
    /// has implemented since 2001; the extensions actually used here
    /// (`statvfs@openssh.com`, `posix-rename@openssh.com`) are negotiated
    /// over it rather than through a newer base version.
    public static let protocolVersion: UInt32 = 3

    /// The hard limit on one frame. SFTP frames carry file data, so the
    /// limit is generous — but a length prefix of 4 GB from a desynchronised
    /// or hostile peer must not become an allocation request.
    public static let maxFrameLength = 256 * 1024 * 1024

    /// The hard limit on one string field (path, handle, data block). A
    /// length prefix larger than this is rejected before a single payload
    /// byte is read, so a corrupt length can never size an allocation.
    public static let maxStringLength = 64 * 1024 * 1024

    /// Message type constants (`SSH_FXP_*`). A plain enum over `UInt8`
    /// constants, not an `enum: UInt8` with cases: decoding must be able to
    /// *report* an unknown type rather than fail to represent it.
    public enum MessageType {
        public static let initialize: UInt8 = 1  // SSH_FXP_INIT
        public static let version: UInt8 = 2  // SSH_FXP_VERSION
        public static let open: UInt8 = 3
        public static let close: UInt8 = 4
        public static let read: UInt8 = 5
        public static let write: UInt8 = 6
        public static let lstat: UInt8 = 7
        public static let fstat: UInt8 = 8
        public static let setstat: UInt8 = 9
        public static let fsetstat: UInt8 = 10
        public static let opendir: UInt8 = 11
        public static let readdir: UInt8 = 12
        public static let remove: UInt8 = 13
        public static let mkdir: UInt8 = 14
        public static let rmdir: UInt8 = 15
        public static let realpath: UInt8 = 16
        public static let stat: UInt8 = 17
        public static let rename: UInt8 = 18
        public static let status: UInt8 = 101
        public static let handle: UInt8 = 102
        public static let data: UInt8 = 103
        public static let name: UInt8 = 104
        public static let attrs: UInt8 = 105
        public static let extended: UInt8 = 200
        public static let extendedReply: UInt8 = 201
    }

    /// The name of the OpenSSH extension that reports filesystem capacity.
    /// A server that does not advertise it in its VERSION gets a plain
    /// `SSH_FX_OP_UNSUPPORTED` answer to it — callers must treat volume
    /// information as unavailable in that case, never guess.
    public static let statVFSExtensionName = "statvfs@openssh.com"

    /// The name of the OpenSSH extension whose RENAME overwrites an
    /// existing destination atomically. Version 3's plain RENAME is
    /// specified to fail when the target exists; OpenSSH's server honours
    /// that, so overwrite-after-rename needs this extension (or a
    /// documented non-atomic REMOVE+RENAME fallback).
    public static let posixRenameExtensionName = "posix-rename@openssh.com"

    // MARK: - Framing

    /// Encodes `message` as a complete frame, length prefix included.
    public static func encodeFrame(_ message: SFTPMessage) -> [UInt8] {
        var writer = SFTPWriter()
        writer.writeUInt8(message.type)
        // INIT and VERSION carry no request-id (§3: those two messages
        // predate request multiplexing).
        if message.type != MessageType.initialize && message.type != MessageType.version {
            writer.writeUInt32(message.requestID)
        }
        message.payload.encode(into: &writer)
        var frame: [UInt8] = []
        frame.reserveCapacity(writer.bytes.count + 4)
        frame.appendUInt32(UInt32(writer.bytes.count))
        frame.append(contentsOf: writer.bytes)
        return frame
    }

    /// Validates a length prefix read from the wire and returns it as an
    /// `Int` to read next. The length covers everything after itself, so
    /// the smallest legal frame is one byte (the type) — INIT's payload is
    /// its version word, but a *frame* containing only a type byte is
    /// malformed in a different way that `decodeFrame` reports.
    public static func validateFrameLength(_ length: UInt32) throws(SFTPCodecError) -> Int {
        guard length >= 1, length <= UInt32(maxFrameLength) else {
            throw .frameLengthOutOfRange(length: UInt64(length), limit: UInt64(maxFrameLength))
        }
        return Int(length)
    }

    /// Decodes one frame body — the `length` bytes after the length prefix.
    /// Any truncation, oversize field or unknown shape is a typed error.
    public static func decodeFrame(_ frame: [UInt8]) throws(SFTPCodecError) -> SFTPMessage {
        var reader = SFTPReader(bytes: frame)
        let type = try reader.readUInt8()
        switch type {
        case MessageType.initialize:
            let version = try reader.readUInt32()
            try reader.requireFinished()
            return SFTPMessage(type: type, requestID: 0, payload: .initialize(version: version))
        case MessageType.version:
            let version = try reader.readUInt32()
            var extensions: [SFTPExtension] = []
            while reader.hasRemaining {
                let name = try reader.readString()
                let data = try reader.readString()
                extensions.append(SFTPExtension(name: name, data: data))
            }
            return SFTPMessage(
                type: type, requestID: 0,
                payload: .version(version: version, extensions: extensions))
        default:
            let requestID = try reader.readUInt32()
            let payload = try SFTPPayload.decode(type: type, from: &reader)
            return SFTPMessage(type: type, requestID: requestID, payload: payload)
        }
    }
}

/// Every way decoding bytes from the peer can fail. Equatable so tests can
/// pin exact failures; no case carries partially decoded state.
public enum SFTPCodecError: Error, Equatable {
    /// A field needed more bytes than the frame had left.
    case truncated(field: String, needed: Int, available: Int)
    /// The frame's length prefix was zero or above `maxFrameLength`.
    case frameLengthOutOfRange(length: UInt64, limit: UInt64)
    /// A string's length prefix exceeded `maxStringLength`.
    case stringLengthOutOfRange(field: String, length: UInt64, limit: UInt64)
    /// The message type byte is not one this version of the protocol defines.
    case unknownMessageType(UInt8)
    /// Bytes remained after the last field of a fixed-layout message.
    case trailingBytes(count: Int)
    /// An ATTRS block's flags named more extended attributes than the
    /// remaining bytes could even minimally encode.
    case extendedAttributeCountOutOfRange(count: UInt64, available: Int)
}

// MARK: - Wire value types

/// ATTRS (§5): the file-metadata block. Every field is optional on the
/// wire; the flags word says which are present. Times are seconds since
/// the unix epoch, as the protocol's `uint32`.
public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var userID: UInt32?
    public var groupID: UInt32?
    /// The POSIX mode bits, exactly as `st_mode` carries them.
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?
    /// Server-specific name/value pairs; both sides raw bytes.
    public var extended: [SFTPExtension]

    public init(
        size: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: UInt32? = nil,
        modificationTime: UInt32? = nil,
        extended: [SFTPExtension] = []
    ) {
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
        self.extended = extended
    }

    /// True when nothing is set — the ATTRS block sent with a READ-ONLY
    /// open or any request that carries no metadata to apply.
    public var isEmpty: Bool {
        size == nil && userID == nil && groupID == nil && permissions == nil
            && accessTime == nil && modificationTime == nil && extended.isEmpty
    }

    static let flagSize: UInt32 = 0x0000_0001
    static let flagIDs: UInt32 = 0x0000_0002
    static let flagPermissions: UInt32 = 0x0000_0004
    static let flagTimes: UInt32 = 0x0000_0008
    static let flagExtended: UInt32 = 0x8000_0000
}

/// A name/value pair in ATTRS's extended section or VERSION's extension
/// list. Raw bytes on both sides: the names are ASCII by convention but
/// the protocol never says so.
public struct SFTPExtension: Equatable, Sendable {
    public var name: [UInt8]
    public var data: [UInt8]

    public init(name: [UInt8], data: [UInt8]) {
        self.name = name
        self.data = data
    }

    /// The name as a string, for comparison against the well-known
    /// extension names (which are ASCII). Lossy for a non-UTF-8 name,
    /// which is acceptable: such a name simply matches nothing.
    public var nameString: String { String(decoding: name, as: UTF8.self) }
}

/// One entry of a NAME response (a directory listing, or REALPATH's single
/// answer). `filename` is the raw name as the server sent it.
public struct SFTPEntry: Equatable, Sendable {
    public var filename: [UInt8]
    /// The server's display rendering ("long format"). Kept for debugging;
    /// nothing should parse it.
    public var longname: [UInt8]
    public var attributes: SFTPAttributes

    public init(filename: [UInt8], longname: [UInt8] = [], attributes: SFTPAttributes = .init()) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }

    /// The name as UTF-8, for display only. Lossy by design — a name that
    /// is not UTF-8 must still survive a round trip through `filename`.
    public var filenameUTF8: String { String(decoding: filename, as: UTF8.self) }
}

/// STATUS (§8.1): the server's answer to every request that has no payload
/// of its own, and its way of failing any request. The well-known codes
/// are statics, not enum cases, so a code this version does not define
/// (§8.1 permits later versions to add more) still round-trips.
public struct SFTPStatus: Equatable, Sendable {
    public struct Code: RawRepresentable, Equatable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let ok = Code(rawValue: 0)  // SSH_FX_OK
        public static let endOfFile = Code(rawValue: 1)  // SSH_FX_EOF
        public static let noSuchFile = Code(rawValue: 2)
        public static let permissionDenied = Code(rawValue: 3)
        public static let failure = Code(rawValue: 4)  // SSH_FX_FAILURE
        public static let badMessage = Code(rawValue: 5)
        public static let noConnection = Code(rawValue: 6)
        public static let connectionLost = Code(rawValue: 7)
        public static let operationUnsupported = Code(rawValue: 8)
    }

    public var code: Code
    /// The server's human-readable explanation, raw. ISO-10646 UTF-8 per
    /// the draft, but a buggy or hostile server can send anything.
    public var message: [UInt8]
    /// The language tag of `message` (§8.1), raw for the same reason.
    public var languageTag: [UInt8]

    public init(code: Code, message: [UInt8] = [], languageTag: [UInt8] = []) {
        self.code = code
        self.message = message
        self.languageTag = languageTag
    }

    public var messageString: String { String(decoding: message, as: UTF8.self) }

    /// True for the statuses that answer a question definitively — as
    /// opposed to transport trouble, which retrying might get past. The
    /// transfer engine's retry policy keys off this: a definitive server
    /// answer is never retried.
    public var isDefinitiveAnswer: Bool { true }
}

/// The pflags word of OPEN (§8.1.1).
public struct SFTPOpenFlags: OptionSet, Equatable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    public static let exclude = SFTPOpenFlags(rawValue: 0x0000_0020)
}

/// A decoded message: its type byte, its request-id (0 for INIT/VERSION,
/// which carry none), and its typed payload.
public struct SFTPMessage: Equatable, Sendable {
    public var type: UInt8
    public var requestID: UInt32
    public var payload: SFTPPayload

    public init(type: UInt8, requestID: UInt32, payload: SFTPPayload) {
        self.type = type
        self.requestID = requestID
        self.payload = payload
    }

    /// Builds a request message; the type byte is implied by the payload.
    public init(requestID: UInt32, request payload: SFTPPayload) {
        self.init(type: payload.type, requestID: requestID, payload: payload)
    }
}

/// The typed payload of every message this client sends or understands.
/// EXTENDED's trailing data and EXTENDED_REPLY's whole body are opaque to
/// the base protocol (the extension defines them), so they stay raw bytes.
public enum SFTPPayload: Equatable, Sendable {
    // Handshake.
    case initialize(version: UInt32)
    case version(version: UInt32, extensions: [SFTPExtension])

    // Requests.
    case open(path: [UInt8], flags: SFTPOpenFlags, attributes: SFTPAttributes)
    case close(handle: [UInt8])
    case read(handle: [UInt8], offset: UInt64, length: UInt32)
    case write(handle: [UInt8], offset: UInt64, data: [UInt8])
    case lstat(path: [UInt8])
    case fstat(handle: [UInt8])
    case setstat(path: [UInt8], attributes: SFTPAttributes)
    case fsetstat(handle: [UInt8], attributes: SFTPAttributes)
    case opendir(path: [UInt8])
    case readdir(handle: [UInt8])
    case remove(path: [UInt8])
    case mkdir(path: [UInt8], attributes: SFTPAttributes)
    case rmdir(path: [UInt8])
    case realpath(path: [UInt8])
    case stat(path: [UInt8])
    case rename(oldPath: [UInt8], newPath: [UInt8])
    case extended(name: [UInt8], data: [UInt8])

    // Responses.
    case status(SFTPStatus)
    case handle([UInt8])
    case data([UInt8])
    case name([SFTPEntry])
    case attrs(SFTPAttributes)
    case extendedReply([UInt8])

    /// The message type byte this payload encodes under.
    public var type: UInt8 {
        switch self {
        case .initialize: SFTPCodec.MessageType.initialize
        case .version: SFTPCodec.MessageType.version
        case .open: SFTPCodec.MessageType.open
        case .close: SFTPCodec.MessageType.close
        case .read: SFTPCodec.MessageType.read
        case .write: SFTPCodec.MessageType.write
        case .lstat: SFTPCodec.MessageType.lstat
        case .fstat: SFTPCodec.MessageType.fstat
        case .setstat: SFTPCodec.MessageType.setstat
        case .fsetstat: SFTPCodec.MessageType.fsetstat
        case .opendir: SFTPCodec.MessageType.opendir
        case .readdir: SFTPCodec.MessageType.readdir
        case .remove: SFTPCodec.MessageType.remove
        case .mkdir: SFTPCodec.MessageType.mkdir
        case .rmdir: SFTPCodec.MessageType.rmdir
        case .realpath: SFTPCodec.MessageType.realpath
        case .stat: SFTPCodec.MessageType.stat
        case .rename: SFTPCodec.MessageType.rename
        case .extended: SFTPCodec.MessageType.extended
        case .status: SFTPCodec.MessageType.status
        case .handle: SFTPCodec.MessageType.handle
        case .data: SFTPCodec.MessageType.data
        case .name: SFTPCodec.MessageType.name
        case .attrs: SFTPCodec.MessageType.attrs
        case .extendedReply: SFTPCodec.MessageType.extendedReply
        }
    }

    /// Whether this payload's message carries a request-id on the wire.
    var hasRequestID: Bool {
        switch self {
        case .initialize, .version: false
        default: true
        }
    }

    func encode(into writer: inout SFTPWriter) {
        switch self {
        case .initialize(let version):
            writer.writeUInt32(version)
        case .version(let version, let extensions):
            writer.writeUInt32(version)
            for item in extensions {
                writer.writeString(item.name)
                writer.writeString(item.data)
            }
        case .open(let path, let flags, let attributes):
            writer.writeString(path)
            writer.writeUInt32(flags.rawValue)
            writer.writeAttributes(attributes)
        case .close(let handle):
            writer.writeString(handle)
        case .read(let handle, let offset, let length):
            writer.writeString(handle)
            writer.writeUInt64(offset)
            writer.writeUInt32(length)
        case .write(let handle, let offset, let data):
            writer.writeString(handle)
            writer.writeUInt64(offset)
            writer.writeString(data)
        case .lstat(let path):
            writer.writeString(path)
        case .fstat(let handle):
            writer.writeString(handle)
        case .setstat(let path, let attributes):
            writer.writeString(path)
            writer.writeAttributes(attributes)
        case .fsetstat(let handle, let attributes):
            writer.writeString(handle)
            writer.writeAttributes(attributes)
        case .opendir(let path):
            writer.writeString(path)
        case .readdir(let handle):
            writer.writeString(handle)
        case .remove(let path):
            writer.writeString(path)
        case .mkdir(let path, let attributes):
            writer.writeString(path)
            writer.writeAttributes(attributes)
        case .rmdir(let path):
            writer.writeString(path)
        case .realpath(let path):
            writer.writeString(path)
        case .stat(let path):
            writer.writeString(path)
        case .rename(let oldPath, let newPath):
            writer.writeString(oldPath)
            writer.writeString(newPath)
        case .extended(let name, let data):
            writer.writeString(name)
            // Not a string: the extension owns the rest of the frame.
            writer.writeRawBytes(data)
        case .status(let status):
            writer.writeUInt32(status.code.rawValue)
            writer.writeString(status.message)
            writer.writeString(status.languageTag)
        case .handle(let handle):
            writer.writeString(handle)
        case .data(let data):
            writer.writeString(data)
        case .name(let entries):
            writer.writeUInt32(UInt32(entries.count))
            for entry in entries {
                writer.writeString(entry.filename)
                writer.writeString(entry.longname)
                writer.writeAttributes(entry.attributes)
            }
        case .attrs(let attributes):
            writer.writeAttributes(attributes)
        case .extendedReply(let data):
            writer.writeRawBytes(data)
        }
    }

    static func decode(
        type: UInt8, from reader: inout SFTPReader
    ) throws(SFTPCodecError) -> SFTPPayload {
        switch type {
        case SFTPCodec.MessageType.open:
            let path = try reader.readString(field: "open.path")
            let flags = SFTPOpenFlags(rawValue: try reader.readUInt32())
            return .open(
                path: path, flags: flags, attributes: try reader.readAttributes())
        case SFTPCodec.MessageType.close:
            return .close(handle: try reader.readString(field: "close.handle"))
        case SFTPCodec.MessageType.read:
            let handle = try reader.readString(field: "read.handle")
            let offset = try reader.readUInt64()
            let length = try reader.readUInt32()
            return .read(handle: handle, offset: offset, length: length)
        case SFTPCodec.MessageType.write:
            let handle = try reader.readString(field: "write.handle")
            let offset = try reader.readUInt64()
            let data = try reader.readString(field: "write.data")
            return .write(handle: handle, offset: offset, data: data)
        case SFTPCodec.MessageType.lstat:
            return .lstat(path: try reader.readString(field: "lstat.path"))
        case SFTPCodec.MessageType.fstat:
            return .fstat(handle: try reader.readString(field: "fstat.handle"))
        case SFTPCodec.MessageType.setstat:
            let path = try reader.readString(field: "setstat.path")
            return .setstat(path: path, attributes: try reader.readAttributes())
        case SFTPCodec.MessageType.fsetstat:
            let handle = try reader.readString(field: "fsetstat.handle")
            return .fsetstat(handle: handle, attributes: try reader.readAttributes())
        case SFTPCodec.MessageType.opendir:
            return .opendir(path: try reader.readString(field: "opendir.path"))
        case SFTPCodec.MessageType.readdir:
            return .readdir(handle: try reader.readString(field: "readdir.handle"))
        case SFTPCodec.MessageType.remove:
            return .remove(path: try reader.readString(field: "remove.path"))
        case SFTPCodec.MessageType.mkdir:
            let path = try reader.readString(field: "mkdir.path")
            return .mkdir(path: path, attributes: try reader.readAttributes())
        case SFTPCodec.MessageType.rmdir:
            return .rmdir(path: try reader.readString(field: "rmdir.path"))
        case SFTPCodec.MessageType.realpath:
            return .realpath(path: try reader.readString(field: "realpath.path"))
        case SFTPCodec.MessageType.stat:
            return .stat(path: try reader.readString(field: "stat.path"))
        case SFTPCodec.MessageType.rename:
            let oldPath = try reader.readString(field: "rename.oldPath")
            let newPath = try reader.readString(field: "rename.newPath")
            return .rename(oldPath: oldPath, newPath: newPath)
        case SFTPCodec.MessageType.extended:
            let name = try reader.readString(field: "extended.name")
            return .extended(name: name, data: reader.readRemaining())
        case SFTPCodec.MessageType.status:
            let code = SFTPStatus.Code(rawValue: try reader.readUInt32())
            let message = try reader.readString(field: "status.message")
            let languageTag = try reader.readString(field: "status.languageTag")
            return .status(SFTPStatus(code: code, message: message, languageTag: languageTag))
        case SFTPCodec.MessageType.handle:
            return .handle(try reader.readString(field: "handle"))
        case SFTPCodec.MessageType.data:
            return .data(try reader.readString(field: "data"))
        case SFTPCodec.MessageType.name:
            let count = try reader.readUInt32()
            // One entry minimally encodes as two empty strings and an empty
            // ATTRS (4 + 4 + 4 bytes). A count that exceeds what the
            // remaining bytes could minimally hold is rejected up front, so
            // the count never sizes an allocation the frame cannot fill.
            let minimumEntryBytes = 12
            if UInt64(count) > UInt64(reader.remaining / minimumEntryBytes) {
                throw .truncated(
                    field: "name.entries",
                    needed: Int(count) * minimumEntryBytes,
                    available: reader.remaining)
            }
            var entries: [SFTPEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let filename = try reader.readString(field: "name.filename")
                let longname = try reader.readString(field: "name.longname")
                let attributes = try reader.readAttributes()
                entries.append(
                    SFTPEntry(filename: filename, longname: longname, attributes: attributes))
            }
            return .name(entries)
        case SFTPCodec.MessageType.attrs:
            return .attrs(try reader.readAttributes())
        case SFTPCodec.MessageType.extendedReply:
            return .extendedReply(reader.readRemaining())
        default:
            throw SFTPCodecError.unknownMessageType(type)
        }
    }
}

// MARK: - Byte reader / writer

/// A cursor over a frame's bytes. Every read is bounds-checked against the
/// frame's actual length — never against what the peer *claims* — so a
/// truncated or lying frame fails as `.truncated` instead of reading out
/// of bounds.
struct SFTPReader {
    let bytes: [UInt8]
    private(set) var position: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - position }
    var hasRemaining: Bool { remaining > 0 }

    mutating func readUInt8() throws(SFTPCodecError) -> UInt8 {
        guard remaining >= 1 else {
            throw .truncated(field: "uint8", needed: 1, available: remaining)
        }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readUInt32() throws(SFTPCodecError) -> UInt32 {
        guard remaining >= 4 else {
            throw .truncated(field: "uint32", needed: 4, available: remaining)
        }
        defer { position += 4 }
        var value: UInt32 = 0
        for index in position..<(position + 4) {
            value = (value << 8) | UInt32(bytes[index])
        }
        return value
    }

    mutating func readUInt64() throws(SFTPCodecError) -> UInt64 {
        guard remaining >= 8 else {
            throw .truncated(field: "uint64", needed: 8, available: remaining)
        }
        defer { position += 8 }
        var value: UInt64 = 0
        for index in position..<(position + 8) {
            value = (value << 8) | UInt64(bytes[index])
        }
        return value
    }

    /// A protocol string: `uint32 length` plus that many raw bytes. The
    /// length prefix is checked against `maxStringLength` *and* against
    /// the bytes actually remaining before any allocation happens.
    mutating func readString(field: String = "string") throws(SFTPCodecError) -> [UInt8] {
        let length = try readUInt32()
        guard length <= UInt32(SFTPCodec.maxStringLength) else {
            throw .stringLengthOutOfRange(
                field: field, length: UInt64(length),
                limit: UInt64(SFTPCodec.maxStringLength))
        }
        guard remaining >= Int(length) else {
            throw .truncated(field: field, needed: Int(length), available: remaining)
        }
        defer { position += Int(length) }
        return Array(bytes[position..<(position + Int(length))])
    }

    mutating func readAttributes() throws(SFTPCodecError) -> SFTPAttributes {
        let flags = try readUInt32()
        var attributes = SFTPAttributes()
        if flags & SFTPAttributes.flagSize != 0 {
            attributes.size = try readUInt64()
        }
        if flags & SFTPAttributes.flagIDs != 0 {
            attributes.userID = try readUInt32()
            attributes.groupID = try readUInt32()
        }
        if flags & SFTPAttributes.flagPermissions != 0 {
            attributes.permissions = try readUInt32()
        }
        if flags & SFTPAttributes.flagTimes != 0 {
            attributes.accessTime = try readUInt32()
            attributes.modificationTime = try readUInt32()
        }
        if flags & SFTPAttributes.flagExtended != 0 {
            let count = try readUInt32()
            // One extended attribute minimally encodes as two empty
            // strings (8 bytes); see the NAME count check.
            if UInt64(count) > UInt64(remaining / 8) {
                throw .extendedAttributeCountOutOfRange(
                    count: UInt64(count), available: remaining)
            }
            var extended: [SFTPExtension] = []
            extended.reserveCapacity(Int(count))
            for _ in 0..<count {
                let name = try readString(field: "attrs.extended.name")
                let data = try readString(field: "attrs.extended.data")
                extended.append(SFTPExtension(name: name, data: data))
            }
            attributes.extended = extended
        }
        return attributes
    }

    /// Everything left in the frame — for EXTENDED bodies, whose shape the
    /// extension, not this codec, defines.
    mutating func readRemaining() -> [UInt8] {
        defer { position = bytes.count }
        return Array(bytes[position...])
    }

    /// Fails unless the frame was consumed exactly — a fixed-layout message
    /// with trailing bytes means the peer and this codec disagree about the
    /// layout, which is a protocol violation, not data to ignore.
    func requireFinished() throws(SFTPCodecError) {
        guard remaining == 0 else { throw .trailingBytes(count: remaining) }
    }
}

/// Builds a frame body, big-endian, appending into a single buffer.
struct SFTPWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.appendUInt32(value)
    }

    mutating func writeUInt64(_ value: UInt64) {
        bytes.appendUInt64(value)
    }

    mutating func writeString(_ value: [UInt8]) {
        bytes.appendUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func writeRawBytes(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func writeAttributes(_ attributes: SFTPAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributes.flagSize }
        if attributes.userID != nil || attributes.groupID != nil {
            flags |= SFTPAttributes.flagIDs
        }
        if attributes.permissions != nil { flags |= SFTPAttributes.flagPermissions }
        if attributes.accessTime != nil || attributes.modificationTime != nil {
            flags |= SFTPAttributes.flagTimes
        }
        if !attributes.extended.isEmpty { flags |= SFTPAttributes.flagExtended }
        writeUInt32(flags)
        if let size = attributes.size { writeUInt64(size) }
        if flags & SFTPAttributes.flagIDs != 0 {
            // The wire always carries the pair; a caller setting one side
            // gets zero for the other, which is what "unknown" means there.
            writeUInt32(attributes.userID ?? 0)
            writeUInt32(attributes.groupID ?? 0)
        }
        if let permissions = attributes.permissions { writeUInt32(permissions) }
        if flags & SFTPAttributes.flagTimes != 0 {
            writeUInt32(attributes.accessTime ?? 0)
            writeUInt32(attributes.modificationTime ?? 0)
        }
        if !attributes.extended.isEmpty {
            writeUInt32(UInt32(attributes.extended.count))
            for item in attributes.extended {
                writeString(item.name)
                writeString(item.data)
            }
        }
    }
}

extension [UInt8] {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
