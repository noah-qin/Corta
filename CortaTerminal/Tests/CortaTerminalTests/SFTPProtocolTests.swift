import Foundation
import Testing

@testable import CortaTerminal

/// B14 — the SFTPv3 codec against hand-computed wire bytes. Every message
/// type round-trips through exact bytes, and truncated, lying or oversize
/// input fails as a typed error — never a trap, never a giant allocation.
@Suite("SFTP protocol codec")
struct SFTPProtocolTests {
    // Byte helpers, so the golden sequences below read as the wire layout.
    private func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
    }

    private func be64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> UInt64(56 - 8 * $0)) & 0xff) }
    }

    private func s(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return be32(UInt32(bytes.count)) + bytes
    }

    private func frame(_ body: [UInt8]) -> [UInt8] {
        be32(UInt32(body.count)) + body
    }

    // MARK: - Handshake

    @Test("INIT encodes to its five-byte body")
    func initialize() throws {
        let message = SFTPMessage(
            type: SFTPCodec.MessageType.initialize, requestID: 0,
            payload: .initialize(version: 3))
        #expect(SFTPCodec.encodeFrame(message) == frame([0x01] + be32(3)))

        let decoded = try SFTPCodec.decodeFrame([0x01] + be32(3))
        #expect(decoded.payload == .initialize(version: 3))
        #expect(decoded.requestID == 0)
    }

    @Test("VERSION carries extension pairs")
    func version() throws {
        // VERSION 3, one extension: "hardlink@openssh.com" = "1".
        let body =
            [0x02] + be32(3)
            + s("hardlink@openssh.com") + s("1")
        let decoded = try SFTPCodec.decodeFrame(body)
        guard case .version(let version, let extensions) = decoded.payload else {
            Issue.record("expected a VERSION payload")
            return
        }
        #expect(version == 3)
        #expect(extensions == [SFTPExtension(name: Array("hardlink@openssh.com".utf8), data: [0x31])])

        // Round-trip: encode(decode(x)) == x.
        #expect(SFTPCodec.encodeFrame(decoded) == frame(body))
    }

    @Test("INIT with trailing bytes is a violation, not data to ignore")
    func initTrailingBytes() {
        #expect(throws: SFTPCodecError.self) {
            try SFTPCodec.decodeFrame([0x01] + be32(3) + [0xff])
        }
    }

    // MARK: - Requests

    @Test("OPEN encodes path, pflags and ATTRS")
    func open() throws {
        // id 7, "/tmp/x", SSH_FXF_READ|WRITE|CREAT (0x0B), empty ATTRS.
        let message = SFTPMessage(
            requestID: 7,
            request: .open(
                path: Array("/tmp/x".utf8),
                flags: [.read, .write, .create],
                attributes: SFTPAttributes()))
        let body = [0x03] + be32(7) + s("/tmp/x") + be32(0x0b) + be32(0)
        #expect(SFTPCodec.encodeFrame(message) == frame(body))

        let decoded = try SFTPCodec.decodeFrame(body)
        #expect(decoded == message)
    }

    @Test("READ carries a 64-bit offset")
    func read() throws {
        let handle = [UInt8]("h".utf8)
        let message = SFTPMessage(
            requestID: 7,
            request: .read(handle: handle, offset: 0x0102_0304_0506_0708, length: 1024))
        let body =
            [0x05] + be32(7) + s("h")
            + [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
            + be32(1024)
        #expect(SFTPCodec.encodeFrame(message) == frame(body))
        #expect(try SFTPCodec.decodeFrame(body) == message)
    }

    @Test("WRITE carries its data as a string")
    func write() throws {
        let message = SFTPMessage(
            requestID: 3,
            request: .write(handle: [0xaa], offset: 9, data: [0xde, 0xad]))
        let body = [0x06] + be32(3) + be32(1) + [0xaa] + be64(9) + be32(2) + [0xde, 0xad]
        #expect(SFTPCodec.encodeFrame(message) == frame(body))
        #expect(try SFTPCodec.decodeFrame(body) == message)
    }

    @Test("single-string requests encode and decode")
    func singleStringRequests() throws {
        let path = Array("/some/where".utf8)
        let cases: [(UInt8, SFTPPayload)] = [
            (7, .lstat(path: path)),
            (8, .fstat(handle: path)),
            (11, .opendir(path: path)),
            (12, .readdir(handle: path)),
            (13, .remove(path: path)),
            (15, .rmdir(path: path)),
            (16, .realpath(path: path)),
            (17, .stat(path: path)),
            (4, .close(handle: path)),
        ]
        for (type, payload) in cases {
            let message = SFTPMessage(requestID: 42, request: payload)
            let body = [type] + be32(42) + s("/some/where")
            #expect(SFTPCodec.encodeFrame(message) == frame(body), "type \(type)")
            #expect(try SFTPCodec.decodeFrame(body) == message, "type \(type)")
        }
    }

    @Test("SETSTAT, FSETSTAT and MKDIR carry ATTRS")
    func attributeCarryingRequests() throws {
        let attrs = SFTPAttributes(permissions: 0o100644)
        let cases: [(UInt8, SFTPPayload, [UInt8])] = [
            (9, .setstat(path: [0x2f], attributes: attrs), s("/") + be32(4) + be32(0o100644)),
            (10, .fsetstat(handle: [0x2f], attributes: attrs), s("/") + be32(4) + be32(0o100644)),
            (14, .mkdir(path: [0x2f], attributes: attrs), s("/") + be32(4) + be32(0o100644)),
        ]
        for (type, payload, tail) in cases {
            let message = SFTPMessage(requestID: 1, request: payload)
            #expect(SFTPCodec.encodeFrame(message) == frame([type] + be32(1) + tail))
            #expect(try SFTPCodec.decodeFrame([type] + be32(1) + tail) == message)
        }
    }

    @Test("RENAME carries two paths")
    func rename() throws {
        let message = SFTPMessage(
            requestID: 5, request: .rename(oldPath: Array("/a".utf8), newPath: Array("/b".utf8)))
        let body = [0x12] + be32(5) + s("/a") + s("/b")
        #expect(SFTPCodec.encodeFrame(message) == frame(body))
        #expect(try SFTPCodec.decodeFrame(body) == message)
    }

    @Test("EXTENDED keeps its body opaque")
    func extended() throws {
        // statvfs@openssh.com with its string-path argument; the codec
        // must not interpret the body past the extension name.
        var statvfsBody: [UInt8] = []
        statvfsBody.appendUInt32(UInt32("/".utf8.count))
        statvfsBody.append(contentsOf: "/".utf8)
        let message = SFTPMessage(
            requestID: 8,
            request: .extended(
                name: Array(SFTPCodec.statVFSExtensionName.utf8), data: statvfsBody))
        let body = [200] + be32(8) + s(SFTPCodec.statVFSExtensionName) + statvfsBody
        #expect(SFTPCodec.encodeFrame(message) == frame(body))
        #expect(try SFTPCodec.decodeFrame(body) == message)
    }

    // MARK: - Responses

    @Test("STATUS carries code, message and language tag")
    func status() throws {
        let body = [101] + be32(9) + be32(4) + s("boom") + s("en")
        let decoded = try SFTPCodec.decodeFrame(body)
        #expect(
            decoded.payload
                == .status(
                    SFTPStatus(
                        code: .failure, message: Array("boom".utf8),
                        languageTag: Array("en".utf8))))
        #expect(SFTPCodec.encodeFrame(decoded) == frame(body))
    }

    @Test("an unknown STATUS code round-trips instead of failing")
    func unknownStatusCode() throws {
        // Later protocol versions may define codes this one does not know
        // (§8.1); decoding must not reject them.
        let body = [101] + be32(1) + be32(0xdead_beef) + s("") + s("")
        let decoded = try SFTPCodec.decodeFrame(body)
        guard case .status(let status) = decoded.payload else {
            Issue.record("expected a STATUS payload")
            return
        }
        #expect(status.code.rawValue == 0xdead_beef)
    }

    @Test("HANDLE, DATA and ATTRS payloads round-trip")
    func handleDataAttrs() throws {
        let handleBody = [102] + be32(1) + s("opaque-handle")
        #expect(
            try SFTPCodec.decodeFrame(handleBody)
                == SFTPMessage(requestID: 1, request: .handle(Array("opaque-handle".utf8))))

        let dataBody = [103] + be32(2) + be32(3) + [0x00, 0xff, 0x7f]
        #expect(
            try SFTPCodec.decodeFrame(dataBody)
                == SFTPMessage(requestID: 2, request: .data([0x00, 0xff, 0x7f])))

        let attrsBody = [105] + be32(3) + be32(1) + be64(42)
        #expect(
            try SFTPCodec.decodeFrame(attrsBody)
                == SFTPMessage(requestID: 3, request: .attrs(SFTPAttributes(size: 42))))
    }

    @Test("NAME carries a vector of entries")
    func name() throws {
        let entry = SFTPEntry(
            filename: Array("a".utf8), longname: [],
            attributes: SFTPAttributes(size: 42))
        let body = [104] + be32(6) + be32(1) + s("a") + s("") + be32(1) + be64(42)
        let decoded = try SFTPCodec.decodeFrame(body)
        #expect(decoded.payload == .name([entry]))
        #expect(SFTPCodec.encodeFrame(decoded) == frame(body))
    }

    // MARK: - ATTRS

    @Test("ATTRS encodes every field in flag order")
    func attributesAllFields() throws {
        let attributes = SFTPAttributes(
            size: 0x0102, userID: 501, groupID: 20,
            permissions: 0o100644, accessTime: 111, modificationTime: 222,
            extended: [SFTPExtension(name: Array("x".utf8), data: [0x01])])
        var writer = SFTPWriter()
        writer.writeAttributes(attributes)
        let expected =
            be32(0x8000_000f)
            + be64(0x0102) + be32(501) + be32(20) + be32(0o100644)
            + be32(111) + be32(222)
            + be32(1) + s("x") + be32(1) + [0x01]
        #expect(writer.bytes == expected)

        // Decode through an ATTRS message.
        let decoded = try SFTPCodec.decodeFrame([105] + be32(1) + expected)
        #expect(decoded.payload == .attrs(attributes))
    }

    @Test("an empty ATTRS is a zero flags word")
    func attributesEmpty() throws {
        let decoded = try SFTPCodec.decodeFrame([105] + be32(1) + be32(0))
        #expect(decoded.payload == .attrs(SFTPAttributes()))
    }

    // MARK: - Filenames are raw bytes

    @Test("non-UTF-8 filenames survive decoding")
    func rawFilenames() throws {
        // 0xff 0xfe is not valid UTF-8; the name must survive as bytes and
        // the UTF-8 view degrades rather than trap or lie.
        let body = [104] + be32(1) + be32(1) + be32(2) + [0xff, 0xfe] + s("") + be32(0)
        let decoded = try SFTPCodec.decodeFrame(body)
        guard case .name(let entries) = decoded.payload else {
            Issue.record("expected a NAME payload")
            return
        }
        #expect(entries[0].filename == [0xff, 0xfe])
        #expect(entries[0].filenameUTF8 == "\u{fffd}\u{fffd}")
    }

    // MARK: - Hostile input

    @Test("truncation at every offset of a NAME frame is a typed error")
    func truncatedName() {
        let full = [104] + be32(6) + be32(1) + s("a") + s("long") + be32(1) + be64(42)
        for cut in 1..<full.count {
            #expect(throws: SFTPCodecError.self, "cut at \(cut)") {
                try SFTPCodec.decodeFrame(Array(full[0..<cut]))
            }
        }
    }

    @Test("truncation at every offset of an OPEN frame is a typed error")
    func truncatedOpen() {
        let attrs = SFTPAttributes(size: 1, userID: 2, groupID: 3, permissions: 4,
                                   accessTime: 5, modificationTime: 6)
        let message = SFTPMessage(
            requestID: 7,
            request: .open(path: Array("/tmp/x".utf8), flags: [.read, .write], attributes: attrs))
        let full = Array(SFTPCodec.encodeFrame(message).dropFirst(4))
        for cut in 1..<full.count {
            #expect(throws: SFTPCodecError.self, "cut at \(cut)") {
                try SFTPCodec.decodeFrame(Array(full[0..<cut]))
            }
        }
    }

    @Test("a lying string length is rejected before allocation")
    func oversizeStringLength() {
        // LSTAT claiming a 4 GB path with nothing behind it.
        let body = [7] + be32(1) + [0xff, 0xff, 0xff, 0xff]
        #expect(throws: SFTPCodecError.stringLengthOutOfRange(
            field: "lstat.path", length: 0xffff_ffff,
            limit: UInt64(SFTPCodec.maxStringLength)))
        {
            try SFTPCodec.decodeFrame(body)
        }
        // A plausible-but-lying length: 1 MB claimed, 3 bytes present.
        let short = [7] + be32(1) + be32(1024 * 1024) + [0x2f, 0x2f, 0x2f]
        #expect(throws: SFTPCodecError.truncated(field: "lstat.path", needed: 1024 * 1024, available: 3)) {
            try SFTPCodec.decodeFrame(short)
        }
    }

    @Test("a lying NAME count is rejected up front")
    func oversizeNameCount() {
        // 16 million entries claimed, nothing behind the count.
        let body = [104] + be32(1) + be32(16_000_000)
        #expect(throws: SFTPCodecError.self) {
            try SFTPCodec.decodeFrame(body)
        }
    }

    @Test("a lying extended-attribute count is rejected up front")
    func oversizeExtendedAttributeCount() {
        let body = [105] + be32(1) + be32(0x8000_0000) + be32(1_000_000)
        #expect(throws: SFTPCodecError.extendedAttributeCountOutOfRange(count: 1_000_000, available: 0)) {
            try SFTPCodec.decodeFrame(body)
        }
    }

    @Test("an unknown message type is a typed error")
    func unknownMessageType() {
        #expect(throws: SFTPCodecError.unknownMessageType(99)) {
            try SFTPCodec.decodeFrame([99] + be32(1))
        }
    }

    @Test("an empty frame body cannot decode")
    func emptyFrame() {
        #expect(throws: SFTPCodecError.self) {
            try SFTPCodec.decodeFrame([])
        }
    }

    @Test("frame length validation bounds the read buffer")
    func frameLengthValidation() throws {
        #expect(throws: SFTPCodecError.frameLengthOutOfRange(length: 0, limit: UInt64(SFTPCodec.maxFrameLength))) {
            try SFTPCodec.validateFrameLength(0)
        }
        #expect(throws: SFTPCodecError.self) {
            try SFTPCodec.validateFrameLength(UInt32(SFTPCodec.maxFrameLength) + 1)
        }
        #expect(try SFTPCodec.validateFrameLength(5) == 5)
        #expect(try SFTPCodec.validateFrameLength(UInt32(SFTPCodec.maxFrameLength)) == SFTPCodec.maxFrameLength)
    }
}
