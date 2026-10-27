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
import Synchronization
import Testing

@testable import CortaSFTP

/// SFTP test support — an in-memory transport pair and a scripted SFTP
/// server, so the session and transfer engine can be driven end to end
/// without a real ssh, a network, or any machine state.
///
/// `SFTPLoopbackConnection` is one bidirectional byte pipe; its two
/// `Transport` views face the client session and the fake server. Closing
/// either side breaks the connection in both directions, the way a dying
/// ssh subprocess breaks the real channel.
///
/// `FakeSFTPServer` speaks the server half of SFTPv3 over its transport
/// against a `FakeRemoteFileSystem`, with hooks for the failure modes the
/// suites need: dropping the connection mid-transfer, delaying replies so
/// the client's in-flight window can be observed, refusing paths, and
/// recording the exact request sequence (which is what makes the
/// atomic-rename and CLOSE-on-cancel assertions possible).

/// A ceiling in seconds (the rig's idle-read deadline, which an
/// `NSCondition` takes as a `Date`, and its log polling), scaled by `CORTA_TEST_TIMEOUT_SCALE` for the sanitizer lane —
/// the same rule as `CortaTerminalTests`' `testTimeout`, repeated because
/// test targets cannot share a file.
func testTimeoutInterval(_ seconds: TimeInterval) -> TimeInterval {
    let scale = ProcessInfo.processInfo.environment["CORTA_TEST_TIMEOUT_SCALE"]
        .flatMap(Int.init) ?? 1
    return seconds * TimeInterval(max(1, scale))
}

/// How the fake server answers one request when its interceptor speaks.
enum FakeServerAction {
    /// Keep the channel open without answering, for cancellation tests.
    case ignore
    /// Fall through to the filesystem's default handling.
    case proceed
    /// Reply with this payload instead.
    case reply(SFTPPayload)
    /// Send these bytes as a complete frame body (post length-prefix),
    /// bypassing the codec — for protocol-violation tests.
    case replyRaw([UInt8])
    /// Close the connection without replying.
    case dropConnection
}

/// What the server saw, for assertions: every request's type name and
/// first path-ish field, in order, plus concurrency high-water marks.
struct FakeServerLog: Equatable {
    var operations: [String] = []
    var readOffsets: [UInt64] = []
    var writePaths: [String] = []
    var closeCount = 0
    var maxOutstandingReads = 0
}

final class FakeSFTPServer: @unchecked Sendable {
    let fileSystem: FakeRemoteFileSystem

    /// Consulted before default handling for every request after INIT.
    private let interceptorStorage = Mutex<(@Sendable (SFTPMessage) -> FakeServerAction)?>(nil)

    /// Extensions advertised in VERSION, e.g. "statvfs@openssh.com".
    var advertisedExtensions: [String] = []

    /// How many entries one READDIR batch carries.
    var readDirBatchSize = 4

    /// The most one READ answers, whatever was asked: the protocol lets a
    /// server reply short anywhere, not only at end of file.
    var maximumReadReply = Int.max

    /// Delay before answering READ/READDIR: gives the client's window time
    /// to fill so `maxOutstandingReads` measures the real concurrency.
    var replyDelay: Duration = .zero

    /// The reply body for a `statvfs@openssh.com` extended request; when
    /// nil and the extension was advertised anyway, OP_UNSUPPORTED.
    var statVFSReply: SFTPVolumeInfo? = SFTPVolumeInfo(
        blockSize: 4096, fragmentSize: 4096,
        blocks: 1000, blocksFree: 500, blocksAvailable: 400,
        files: 2000, filesFree: 1500, filesAvailable: 1400,
        filesystemID: 7, flags: 0, nameMaximum: 255)

    /// OPENs of these paths are refused with PERMISSION_DENIED.
    var refusedPaths: Set<String> = []

    let state = Mutex(State())

    private let writeLock = NSLock()

    private let transport: SFTPLoopbackConnection.Transport

    init(connection: SFTPLoopbackConnection, fileSystem: FakeRemoteFileSystem) {
        self.fileSystem = fileSystem
        self.transport = connection.serverTransport()
    }

    var interceptor: (@Sendable (SFTPMessage) -> FakeServerAction)? {
        get { interceptorStorage.withLock { $0 } }
        set { interceptorStorage.withLock { $0 = newValue } }
    }

    struct HandleState {
        enum Kind {
            case file(path: String)
            case directory(path: String, entries: [SFTPEntry], position: Int)
        }

        var kind: Kind
    }

    struct State {
        var log = FakeServerLog()
        var nextHandle: UInt64 = 0
        var handles: [String: HandleState] = [:]
        var outstandingReads = 0
    }

    /// Snapshot of what the server has seen so far.
    var log: FakeServerLog { state.withLock { $0.log } }

    /// Runs the request loop on its own thread until the connection drops.
    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "dev.corta.tests.fake-sftp-server"
        thread.start()
    }

    /// Waits until the log satisfies `predicate` or the deadline passes.
    /// Polling, but bounded — a missing event fails the test, naming the
    /// `description` it waited for.
    /// A passing test returns from this in milliseconds; the default
    /// `timeout` only decides how long a failing one takes to say so, and
    /// scales with `CORTA_TEST_TIMEOUT_SCALE` like `readDeadline`.
    func waitFor(
        _ description: String,
        timeout: TimeInterval = testTimeoutInterval(15),
        sourceLocation: SourceLocation = #_sourceLocation,
        predicate: (FakeServerLog) -> Bool
    ) {
        let deadline = SuspendingClock.now + .seconds(timeout)
        while SuspendingClock.now < deadline {
            if predicate(log) { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(predicate(log), "timed out waiting for \(description)", sourceLocation: sourceLocation)
    }

    // MARK: - Request loop

    private func run() {
        while true {
            do {
                var lengthBytes = [UInt8](repeating: 0, count: 4)
                guard try readExact(&lengthBytes) else { return }
                let length = (UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16)
                    | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3])
                var frame = [UInt8](repeating: 0, count: Int(length))
                guard try readExact(&frame) else { return }
                let message = try SFTPCodec.decodeFrame(frame)
                handle(message)
            } catch {
                // EOF, a closed connection, or undecodable bytes from the
                // client: either way this conversation is over.
                transport.close()
                return
            }
        }
    }

    private func readExact(_ buffer: inout [UInt8]) throws -> Bool {
        var filled = 0
        while filled < buffer.count {
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                try transport.read(
                    into: UnsafeMutableRawBufferPointer(
                        start: raw.baseAddress! + filled, count: raw.count - filled))
            }
            if count == 0 { return false }
            filled += count
        }
        return true
    }

    func send(_ payload: SFTPPayload, requestID: UInt32) {
        let frame = SFTPCodec.encodeFrame(SFTPMessage(requestID: requestID, request: payload))
        writeLock.lock()
        defer { writeLock.unlock() }
        try? frame.withUnsafeBytes { try transport.write($0) }
    }

    private func sendRaw(_ body: [UInt8]) {
        var frame: [UInt8] = []
        frame.appendUInt32(UInt32(body.count))
        frame.append(contentsOf: body)
        writeLock.lock()
        defer { writeLock.unlock() }
        try? frame.withUnsafeBytes { try transport.write($0) }
    }

    private func handle(_ message: SFTPMessage) {
        if case .initialize = message.payload {
            send(
                .version(
                    version: SFTPCodec.protocolVersion,
                    extensions: advertisedExtensions.map {
                        SFTPExtension(name: Array($0.utf8), data: [0x31])
                    }),
                requestID: 0)
            return
        }

        record(message)

        if let action = interceptor?(message) {
            switch action {
            case .proceed:
                break
            case .ignore:
                return
            case .reply(let payload):
                send(payload, requestID: message.requestID)
                return
            case .replyRaw(let body):
                sendRaw(body)
                return
            case .dropConnection:
                transport.close()
                return
            }
        }

        if replyDelay > .zero, case .read = message.payload {
            // Answer asynchronously so the client's window can fill while
            // this request is outstanding.
            state.withLock {
                $0.outstandingReads += 1
                $0.log.maxOutstandingReads = max(
                    $0.log.maxOutstandingReads, $0.outstandingReads)
            }
            let delay = replyDelay
            Thread.detachNewThread { [weak self] in
                let seconds = TimeInterval(delay.components.seconds)
                    + TimeInterval(delay.components.attoseconds) / 1e18
                Thread.sleep(forTimeInterval: seconds + 0.001)
                guard let self else { return }
                self.state.withLock { $0.outstandingReads -= 1 }
                self.respondDefault(to: message)
            }
            return
        }

        respondDefault(to: message)
    }

    private func record(_ message: SFTPMessage) {
        state.withLock { state in
            switch message.payload {
            case .open(let path, _, _):
                state.log.operations.append("open \(String(decoding: path, as: UTF8.self))")
            case .close:
                state.log.operations.append("close")
                state.log.closeCount += 1
            case .read(_, let offset, _):
                state.log.operations.append("read @\(offset)")
                state.log.readOffsets.append(offset)
            case .write(_, let offset, let data):
                state.log.operations.append("write @\(offset) \(data.count)b")
            case .opendir(let path):
                state.log.operations.append("opendir \(String(decoding: path, as: UTF8.self))")
            case .readdir:
                state.log.operations.append("readdir")
            case .rename(let old, let new):
                state.log.operations.append(
                    "rename \(String(decoding: old, as: UTF8.self)) -> \(String(decoding: new, as: UTF8.self))")
            case .remove(let path):
                state.log.operations.append("remove \(String(decoding: path, as: UTF8.self))")
            case .stat(let path), .lstat(let path):
                state.log.operations.append("stat \(String(decoding: path, as: UTF8.self))")
            case .setstat(let path, _), .mkdir(let path, _), .rmdir(let path):
                state.log.operations.append("meta \(String(decoding: path, as: UTF8.self))")
            case .fsetstat:
                state.log.operations.append("fsetstat")
            case .extended(let name, _):
                state.log.operations.append("extended \(String(decoding: name, as: UTF8.self))")
            default:
                state.log.operations.append("other \(message.type)")
            }
        }
    }
}

extension FakeSFTPServer {
    // MARK: - Default filesystem behaviour

    private func respondDefault(to message: SFTPMessage) {
        let requestID = message.requestID
        let fail = failure(requestID: requestID)

        switch message.payload {
        case .open: respondOpen(message)

        case .close: respondClose(message)

        case .read: respondRead(message)

        case .write: respondWrite(message)

        case .stat, .lstat: respondStat(message)

        case .setstat: respondSetstat(message)

        case .mkdir(let path, _):
            fileSystem.createDirectory(String(decoding: path, as: UTF8.self))
            fail(.ok, "")

        case .fsetstat: respondFsetstat(message)

        case .opendir: respondOpendir(message)

        case .readdir: respondReaddir(message)

        case .remove(let path):
            fileSystem.removeFile(String(decoding: path, as: UTF8.self))
            fail(.ok, "")

        case .rmdir:
            fail(.ok, "")

        case .rename: respondRename(message)

        case .realpath(let path):
            send(
                .name([SFTPEntry(filename: path)]),
                requestID: requestID)

        case .extended: respondExtended(message)

        default:
            fail(.operationUnsupported, "unsupported by the fake")
        }
    }

    /// Replies to `requestID` with a status and its message.
    func failure(requestID: UInt32) -> (SFTPStatus.Code, String) -> Void {
        { code, text in
            self.send(
                .status(SFTPStatus(code: code, message: Array(text.utf8), languageTag: Array("en".utf8))),
                requestID: requestID)
        }
    }

    private func respondOpen(_ message: SFTPMessage) {
        guard case .open(let path, let flags, _) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: path, as: UTF8.self)
        if refusedPaths.contains(name) {
            fail(.permissionDenied, "refused by the test")
            return
        }
        if flags.contains(.read), !fileSystem.exists(name) {
            fail(.noSuchFile, "no such file")
            return
        }
        if flags.contains(.write), flags.contains(.exclude), fileSystem.exists(name) {
            fail(.failure, "exists")
            return
        }
        if flags.contains(.create), !fileSystem.exists(name) {
            fileSystem.createFile(name, data: [])
        } else if flags.contains(.truncate), flags.contains(.write) {
            if var file = fileSystem.file(name) {
                file.data = []
                fileSystem.createFile(name, data: [], modificationTime: file.modificationTime)
            }
        }
        let handle = newHandle(.file(path: name))
        send(.handle(Array(handle.utf8)), requestID: requestID)
    }

    private func respondClose(_ message: SFTPMessage) {
        guard case .close(let handle) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: handle, as: UTF8.self)
        let existed = state.withLock { $0.handles.removeValue(forKey: name) != nil }
        if existed {
            fail(.ok, "")
        } else {
            fail(.failure, "no such handle")
        }
    }

    private func respondRead(_ message: SFTPMessage) {
        guard case .read(let handle, let offset, let length) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: handle, as: UTF8.self)
        guard let info = state.withLock({ $0.handles[name] }),
            case .file(let path) = info.kind,
            let file = fileSystem.file(path)
        else {
            fail(.failure, "no such handle")
            return
        }
        if offset >= UInt64(file.data.count) {
            fail(.endOfFile, "eof")
            return
        }
        let end = min(Int(offset) + min(Int(length), maximumReadReply), file.data.count)
        send(.data(Array(file.data[Int(offset)..<end])), requestID: requestID)
    }

    private func respondWrite(_ message: SFTPMessage) {
        guard case .write(let handle, let offset, let data) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: handle, as: UTF8.self)
        state.withLock { state in
            if let info = state.handles[name], case .file(let path) = info.kind {
                state.log.writePaths.append(path)
            }
        }
        guard let info = state.withLock({ $0.handles[name] }),
            case .file(let path) = info.kind,
            var file = fileSystem.file(path)
        else {
            fail(.failure, "no such handle")
            return
        }
        let needed = Int(offset) + data.count
        if file.data.count < needed {
            file.data.append(contentsOf: [UInt8](repeating: 0, count: needed - file.data.count))
        }
        file.data.replaceSubrange(Int(offset)..<needed, with: data)
        fileSystem.createFile(path, data: file.data, modificationTime: file.modificationTime)
        fail(.ok, "")
    }

    private func respondStat(_ message: SFTPMessage) {
        let path: [UInt8]
        switch message.payload {
        case .stat(let statPath), .lstat(let statPath): path = statPath
        default: return
        }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: path, as: UTF8.self)
        if let file = fileSystem.file(name) {
            send(
                .attrs(
                    SFTPAttributes(
                        size: UInt64(file.data.count),
                        permissions: file.permissions,
                        modificationTime: file.modificationTime)),
                requestID: requestID)
        } else if fileSystem.isDirectory(name) {
            send(
                .attrs(SFTPAttributes(permissions: 0o040_755, modificationTime: 1_000)),
                requestID: requestID)
        } else {
            fail(.noSuchFile, "no such file")
        }
    }

    private func respondSetstat(_ message: SFTPMessage) {
        guard case .setstat(let path, let attributes) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: path, as: UTF8.self)
        if var file = fileSystem.file(name) {
            if let size = attributes.size {
                let count = Int(size)
                if count < file.data.count {
                    file.data.removeLast(file.data.count - count)
                } else {
                    file.data.append(contentsOf: repeatElement(0, count: count - file.data.count))
                }
            }
            if let mtime = attributes.modificationTime { file.modificationTime = mtime }
            fileSystem.createFile(name, data: file.data, modificationTime: file.modificationTime)
            fail(.ok, "")
        } else {
            fail(.noSuchFile, "no such file")
        }
    }

    private func respondFsetstat(_ message: SFTPMessage) {
        guard case .fsetstat(let handle, let attributes) = message.payload else { return }
        let requestID = message.requestID
        let fail = failure(requestID: requestID)
        let name = String(decoding: handle, as: UTF8.self)
        guard let info = state.withLock({ $0.handles[name] }),
            case .file(let path) = info.kind,
            var file = fileSystem.file(path)
        else {
            fail(.failure, "no such handle")
            return
        }
        if let mtime = attributes.modificationTime { file.modificationTime = mtime }
        fileSystem.createFile(path, data: file.data, modificationTime: file.modificationTime)
        fail(.ok, "")
    }
}
