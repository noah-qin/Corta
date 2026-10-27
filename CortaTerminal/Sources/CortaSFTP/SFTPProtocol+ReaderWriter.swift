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
        let flags = attributes.wireFlags
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
            writeExtensionPairs(attributes.extended)
        }
    }

    /// Each extension as its name and data strings, uncounted.
    mutating func writeExtensionPairs(_ extensions: [SFTPExtension]) {
        for item in extensions {
            writeString(item.name)
            writeString(item.data)
        }
    }

    /// A NAME reply's count, then each entry's names and attributes.
    mutating func writeEntries(_ entries: [SFTPEntry]) {
        writeUInt32(UInt32(entries.count))
        for entry in entries {
            writeString(entry.filename)
            writeString(entry.longname)
            writeAttributes(entry.attributes)
        }
    }
}

extension SFTPAttributes {
    /// The ATTRS flags word: one bit per field present. The ID and time
    /// fields travel in pairs, so either half sets the pair's bit.
    var wireFlags: UInt32 {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.flagSize }
        if userID != nil || groupID != nil { flags |= Self.flagIDs }
        if permissions != nil { flags |= Self.flagPermissions }
        if accessTime != nil || modificationTime != nil { flags |= Self.flagTimes }
        if !extended.isEmpty { flags |= Self.flagExtended }
        return flags
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
