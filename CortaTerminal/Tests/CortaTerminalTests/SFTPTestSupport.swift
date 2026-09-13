import Darwin
import Foundation
import Synchronization

@testable import CortaTerminal

/// B14 test support — an in-memory transport pair and a scripted SFTP
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

/// One bidirectional in-memory channel.
final class SFTPLoopbackConnection: @unchecked Sendable {
    /// Reads block up to this long before failing, so a broken test fails
    /// instead of hanging the suite.
    static let readDeadline: TimeInterval = 10

    private struct Side {
        var buffer: [UInt8] = []
    }

    private struct State {
        var clientToServer = Side()
        var serverToClient = Side()
        var isClosed = false
    }

    private let condition = NSCondition()
    private var state = State()

    /// The client's end of the channel, for `SFTPSession`.
    func clientTransport() -> Transport { Transport(connection: self, isClientSide: true) }
    /// The server's end, for `FakeSFTPServer`.
    func serverTransport() -> Transport { Transport(connection: self, isClientSide: false) }

    fileprivate func write(_ bytes: [UInt8], fromClient: Bool) throws(SFTPTransportError) {
        condition.lock()
        defer { condition.unlock() }
        guard !state.isClosed else { throw .closed }
        if fromClient {
            state.clientToServer.buffer.append(contentsOf: bytes)
        } else {
            state.serverToClient.buffer.append(contentsOf: bytes)
        }
        condition.broadcast()
    }

    fileprivate func read(into out: UnsafeMutableRawBufferPointer, fromClient: Bool) throws(SFTPTransportError) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        while true {
            let side = fromClient ? state.serverToClient : state.clientToServer
            // Buffered bytes are delivered even after close: a peer that
            // wrote a reply and then died still said it. EOF is closed
            // *and* drained.
            if !side.buffer.isEmpty {
                let count = min(out.count, side.buffer.count)
                side.buffer.withUnsafeBufferPointer { buffer in
                    out.copyMemory(
                        from: UnsafeRawBufferPointer(start: buffer.baseAddress!, count: count))
                }
                if fromClient {
                    state.serverToClient.buffer.removeFirst(count)
                } else {
                    state.clientToServer.buffer.removeFirst(count)
                }
                return count
            }
            if state.isClosed { return 0 }
            if !condition.wait(until: deadline) {
                throw .ioFailed(code: ETIMEDOUT)
            }
        }
    }

    func close() {
        condition.lock()
        state.isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    final class Transport: SFTPChannelTransport, @unchecked Sendable {
        let connection: SFTPLoopbackConnection
        let isClientSide: Bool

        init(connection: SFTPLoopbackConnection, isClientSide: Bool) {
            self.connection = connection
            self.isClientSide = isClientSide
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws(SFTPTransportError) -> Int {
            try connection.read(into: buffer, fromClient: isClientSide)
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError) {
            try connection.write(Array(bytes), fromClient: isClientSide)
        }

        func close() {
            connection.close()
        }
    }
}

/// A tiny remote filesystem: flat maps of paths, POSIX-enough for the
/// transfer engine's needs (sizes, mtimes, directories, existence).
final class FakeRemoteFileSystem: @unchecked Sendable {
    struct File: Equatable {
        var data: [UInt8]
        var modificationTime: UInt32 = 1_000
        var permissions: UInt32 = 0o100_644
    }

    private struct State {
        var files: [String: File] = [:]
        var directories: Set<String> = ["/"]
    }

    private let state = Mutex(State())

    func createFile(_ path: String, data: [UInt8], modificationTime: UInt32 = 1_000) {
        state.withLock { state in
            state.files[path] = File(data: data, modificationTime: modificationTime)
            // Ancestor directories exist implicitly, the way a real
            // filesystem's would.
            var ancestor = path
            while let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex {
                ancestor = String(ancestor[ancestor.startIndex..<slash])
                state.directories.insert(ancestor)
            }
        }
    }

    func createDirectory(_ path: String) {
        _ = state.withLock { $0.directories.insert(path) }
    }

    func file(_ path: String) -> File? { state.withLock { $0.files[path] } }
    func isDirectory(_ path: String) -> Bool { state.withLock { $0.directories.contains(path) } }
    func exists(_ path: String) -> Bool {
        state.withLock { $0.files.keys.contains(path) || $0.directories.contains(path) }
    }

    func removeFile(_ path: String) {
        _ = state.withLock { $0.files.removeValue(forKey: path) }
    }

    func rename(from oldName: String, to newName: String) {
        state.withLock { state in
            if let file = state.files.removeValue(forKey: oldName) {
                state.files[newName] = file
            }
        }
    }

    /// The names directly under a directory, or nil if it is not one.
    func children(of path: String) -> [String]? {
        state.withLock { state -> [String]? in
            guard state.directories.contains(path) else { return nil }
            let prefix = path == "/" ? "/" : path + "/"
            var names: Set<String> = []
            for candidate in Set(state.files.keys).union(state.directories) {
                guard candidate != path, candidate.hasPrefix(prefix) else { continue }
                let rest = String(candidate.dropFirst(prefix.count))
                guard !rest.isEmpty, !rest.contains("/") else { continue }
                names.insert(rest)
            }
            return names.sorted()
        }
    }
}

/// How the fake server answers one request when its interceptor speaks.
enum FakeServerAction {
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
    var interceptor: (@Sendable (SFTPMessage) -> FakeServerAction)?

    /// Extensions advertised in VERSION, e.g. "statvfs@openssh.com".
    var advertisedExtensions: [String] = []

    /// How many entries one READDIR batch carries.
    var readDirBatchSize = 4

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

    private struct HandleState {
        enum Kind {
            case file(path: String)
            case directory(path: String, entries: [SFTPEntry], position: Int)
        }

        var kind: Kind
    }

    private struct State {
        var log = FakeServerLog()
        var nextHandle: UInt64 = 0
        var handles: [String: HandleState] = [:]
        var outstandingReads = 0
    }

    private let state = Mutex(State())
    private let writeLock = NSLock()
    private let transport: SFTPLoopbackConnection.Transport
    private var thread: Thread?

    /// Snapshot of what the server has seen so far.
    var log: FakeServerLog { state.withLock { $0.log } }

    init(connection: SFTPLoopbackConnection, fileSystem: FakeRemoteFileSystem) {
        self.fileSystem = fileSystem
        self.transport = connection.serverTransport()
    }

    /// Runs the request loop on its own thread until the connection drops.
    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "dev.corta.tests.fake-sftp-server"
        self.thread = thread
        thread.start()
    }

    /// Waits until the log satisfies `predicate` or the deadline passes.
    /// Polling, but bounded — a missing event fails the test with what was
    /// actually recorded.
    func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        predicate: (FakeServerLog) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(log) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate(log)
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

    private func send(_ payload: SFTPPayload, requestID: UInt32) {
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

    // MARK: - Default filesystem behaviour

    private func respondDefault(to message: SFTPMessage) {
        let requestID = message.requestID
        let fail: (SFTPStatus.Code, String) -> Void = { code, text in
            self.send(
                .status(SFTPStatus(code: code, message: Array(text.utf8), languageTag: Array("en".utf8))),
                requestID: requestID)
        }

        switch message.payload {
        case .open(let path, let flags, _):
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

        case .close(let handle):
            let name = String(decoding: handle, as: UTF8.self)
            let existed = state.withLock { $0.handles.removeValue(forKey: name) != nil }
            if existed {
                fail(.ok, "")
            } else {
                fail(.failure, "no such handle")
            }

        case .read(let handle, let offset, let length):
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
            let end = min(Int(offset) + Int(length), file.data.count)
            send(.data(Array(file.data[Int(offset)..<end])), requestID: requestID)

        case .write(let handle, let offset, let data):
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

        case .stat(let path), .lstat(let path):
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

        case .setstat(let path, let attributes):
            let name = String(decoding: path, as: UTF8.self)
            if var file = fileSystem.file(name) {
                if let mtime = attributes.modificationTime { file.modificationTime = mtime }
                fileSystem.createFile(name, data: file.data, modificationTime: file.modificationTime)
                fail(.ok, "")
            } else {
                fail(.noSuchFile, "no such file")
            }

        case .mkdir(let path, _):
            fileSystem.createDirectory(String(decoding: path, as: UTF8.self))
            fail(.ok, "")

        case .fsetstat(let handle, let attributes):
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

        case .opendir(let path):
            let name = String(decoding: path, as: UTF8.self)
            guard let children = fileSystem.children(of: name) else {
                fail(.noSuchFile, "no such directory")
                return
            }
            let entries = children.map { child -> SFTPEntry in
                let full = name == "/" ? "/\(child)" : "\(name)/\(child)"
                let attributes: SFTPAttributes
                if let file = fileSystem.file(full) {
                    attributes = SFTPAttributes(
                        size: UInt64(file.data.count), permissions: file.permissions,
                        modificationTime: file.modificationTime)
                } else {
                    attributes = SFTPAttributes(permissions: 0o040_755)
                }
                return SFTPEntry(filename: Array(child.utf8), attributes: attributes)
            }
            let handle = newHandle(.directory(path: name, entries: entries, position: 0))
            send(.handle(Array(handle.utf8)), requestID: requestID)

        case .readdir(let handle):
            let name = String(decoding: handle, as: UTF8.self)
            guard var info = state.withLock({ $0.handles[name] }),
                case .directory(_, let entries, let position) = info.kind
            else {
                fail(.failure, "no such handle")
                return
            }
            if position >= entries.count {
                fail(.endOfFile, "eof")
                return
            }
            let end = min(position + readDirBatchSize, entries.count)
            let batch = Array(entries[position..<end])
            info.kind = .directory(path: name, entries: entries, position: end)
            state.withLock { $0.handles[name] = info }
            send(.name(batch), requestID: requestID)

        case .remove(let path):
            fileSystem.removeFile(String(decoding: path, as: UTF8.self))
            fail(.ok, "")

        case .rmdir:
            fail(.ok, "")

        case .rename(let oldPath, let newPath):
            let oldName = String(decoding: oldPath, as: UTF8.self)
            let newName = String(decoding: newPath, as: UTF8.self)
            // Version 3 semantics: fail when the destination exists.
            if fileSystem.exists(newName) {
                fail(.failure, "destination exists")
                return
            }
            renameOnFileSystem(from: oldName, to: newName)
            fail(.ok, "")

        case .realpath(let path):
            send(
                .name([SFTPEntry(filename: path)]),
                requestID: requestID)

        case .extended(let name, let data):
            let extensionName = String(decoding: name, as: UTF8.self)
            if extensionName == SFTPCodec.statVFSExtensionName {
                guard advertisedExtensions.contains(extensionName), let info = statVFSReply else {
                    fail(.operationUnsupported, "unsupported")
                    return
                }
                var writer = SFTPWriter()
                for value in [
                    info.blockSize, info.fragmentSize, info.blocks, info.blocksFree,
                    info.blocksAvailable, info.files, info.filesFree, info.filesAvailable,
                    info.filesystemID, info.flags, info.nameMaximum,
                ] {
                    writer.writeUInt64(value)
                }
                _ = data
                send(.extendedReply(writer.bytes), requestID: requestID)
            } else if extensionName == SFTPCodec.posixRenameExtensionName {
                guard advertisedExtensions.contains(extensionName) else {
                    fail(.operationUnsupported, "unsupported")
                    return
                }
                var reader = SFTPReader(bytes: data)
                guard let oldPath = try? reader.readString(),
                    let newPath = try? reader.readString()
                else {
                    fail(.badMessage, "bad posix-rename body")
                    return
                }
                renameOnFileSystem(
                    from: String(decoding: oldPath, as: UTF8.self),
                    to: String(decoding: newPath, as: UTF8.self))
                fail(.ok, "")
            } else {
                fail(.operationUnsupported, "unsupported")
            }

        default:
            fail(.operationUnsupported, "unsupported by the fake")
        }
    }

    private func newHandle(_ kind: HandleState.Kind) -> String {
        state.withLock { state in
            state.nextHandle += 1
            let name = "handle-\(state.nextHandle)"
            state.handles[name] = HandleState(kind: kind)
            return name
        }
    }

    private func renameOnFileSystem(from oldName: String, to newName: String) {
        fileSystem.rename(from: oldName, to: newName)
    }
}

extension FakeServerLog {
    /// The paths that were ever the target of a WRITE.
    var writtenPaths: [String] { writePaths }
}
