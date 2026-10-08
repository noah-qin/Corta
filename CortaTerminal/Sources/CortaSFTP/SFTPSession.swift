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
import Dispatch
import Foundation
import Synchronization

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
}

/// One SSH_FXP_* conversation over a channel: request multiplexing,
/// reply dispatch, and the bounded in-flight window.
///
/// Threading mirrors `TerminalSession` (`DECISIONS.md` D04): a dedicated
/// reader `Thread` blocks in the transport's `read` and dispatches replies
/// by request-id; sending is a serial queue of its own, so two requests'
/// frames can never interleave on the wire and a `write(2)` blocked on a
/// full pipe parks that queue's thread, never one of the cooperative pool's.
/// Everything else is async —
/// each request is a continuation the reader resumes — and nothing is
/// isolated to any actor.
///
/// Request-ids are allocated from a bounded space and recycled, with one
/// refinement for cancellation: an id whose request was cancelled while in
/// flight is *not* recycled until the server's late reply for it arrives,
/// because a recycled id would make that late reply indistinguishable from
/// the new request's. Cancelled ids have their own budget: cancellation
/// frees a window slot, but cannot free an unanswered wire id.
public final class SFTPSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The bound on requests sent but not yet answered. Past it,
        /// senders suspend in FIFO order. 32 is generous for latency
        /// hiding without letting a stalled server accumulate unbounded
        /// unreplied frames.
        public var maxInFlightRequests = 32

        /// Unanswered cancelled requests retained for late-reply isolation.
        /// A peer that exhausts this budget ends the session rather than
        /// growing metadata or recycling ids whose replies could still arrive.
        public var maxCancelledRequests = 1_024

        public init() {}
    }

    public let configuration: Configuration
    private let transport: SFTPChannelTransport

    private struct State {
        /// Id allocation, recycling and the three cancellation orderings.
        /// A value, and tested as one — `SFTPRequestIDLedger`.
        var ids = SFTPRequestIDLedger()
        /// Requests the server still owes a reply, by id.
        /// Keyed by id, because that is all a reply off the wire carries
        /// — but each entry remembers *which allocation* it is, so a
        /// cancellation arriving late for a previous holder of the id
        /// cannot resume this one.
        var inFlight:
            [UInt32: (
                ticket: SFTPRequestIDLedger.Ticket,
                continuation: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>
            )] = [:]
        /// Window slots handed out and not yet given back — one per
        /// admitted sender, from `acquireRequestSlot` until its request is
        /// answered, fails, is cancelled, or turns out not to be sent.
        /// Counted separately from `inFlight` because a sender holds its
        /// slot *before* it registers there: a burst of concurrent senders
        /// all passed the `inFlight.count` check while none had registered
        /// yet, and the window bounded nothing.
        var windowUsed = 0
        /// Writer-queue places taken: one per admitted sender, from admission
        /// until its frame is written (or it turns out not to send one), plus
        /// the handshake's. Counted apart from the window: a cancelled request
        /// gives its window slot back at once, but its frame is still queued
        /// behind a blocked write, and cancel-and-retry would grow the queue
        /// without bound. Reserved at admission, never after, so admitting
        /// cannot outrun it.
        var unwrittenFrames = 0
        /// Senders suspended on the window, FIFO by token.
        var windowWaiters: [(token: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
        var nextWindowToken: UInt64 = 0
        /// The INIT handshake's continuation, while connect() is pending.
        var handshake: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>?
        /// Non-nil once the session is over: every later operation fails
        /// with this, and it is the error in-flight requests died with.
        var closed: SFTPError?
        /// Set once VERSION has been consumed.
        var connectStarted = false
        var serverInfo: SFTPServerCapabilities?
    }

    private let state = Mutex(State())
    /// Serialises frame writes; two senders must never interleave bytes
    /// of their frames on the wire. Its own thread: a write blocks while ssh
    /// is slower than the window, and the cooperative pool has one thread
    /// per core for the whole process.
    private let writerQueue = DispatchQueue(label: "dev.corta.sftp.writer", qos: .utility)

    public init(transport: SFTPChannelTransport, configuration: Configuration = .init()) {
        self.transport = transport
        self.configuration = configuration
    }

    /// Frames queued for the writer and not yet written; for tests.
    var handshakePending: Bool { state.withLock { $0.handshake != nil } }

    var unwrittenFrameCount: Int { state.withLock { $0.unwrittenFrames } }

    var retainedLateReplyCount: Int { state.withLock { $0.ids.retainedLateReplyCount } }

    /// The server's capabilities, from its VERSION answer. `nil` until
    /// `connect()` completes.
    public var capabilities: SFTPServerCapabilities? {
        state.withLock { $0.serverInfo }
    }

    // MARK: - Lifecycle

    /// Sends INIT and waits for VERSION. Starts the reader thread; a
    /// session that is never connected still needs `close()` to release
    /// the transport.
    @discardableResult
    public func connect() async throws(SFTPError) -> SFTPServerCapabilities {
        // Reserve the entire lifecycle before starting any reader. Rejecting a
        // second caller must neither start a reader nor cancel the first caller.
        let admissionError = state.withLock { state -> SFTPError? in
            if let closed = state.closed { return closed }
            guard !state.connectStarted else {
                return .protocolViolation("connect() called on a used session")
            }
            state.connectStarted = true
            return nil
        }
        if let admissionError { throw admissionError }

        let message = SFTPMessage(
            type: SFTPCodec.MessageType.initialize, requestID: 0,
            payload: .initialize(version: SFTPCodec.protocolVersion))
        let frame = SFTPCodec.encodeFrame(message)

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>) in
                let failure = state.withLock { state -> SFTPError? in
                    if let closed = state.closed { return closed }
                    if Task.isCancelled { return .cancelled }
                    state.handshake = continuation
                    return nil
                }
                if let failure {
                    continuation.resume(returning: .failure(failure))
                    return
                }
                let thread = Thread { [weak self] in self?.readerLoop() }
                thread.name = "dev.corta.sftp.reader"
                thread.qualityOfService = .utility
                thread.start()
                sendFrame(frame, reserved: false) { [self] error in
                    tearDown(with: error, closingTransport: true)
                }
            }
        } onCancel: {
            self.close()
        }

        let reply = try result.get()
        guard case .version(let version, let extensions) = reply.payload else {
            close()
            throw .protocolViolation("the server's first message was not VERSION")
        }
        // This client speaks version 3; a server answering lower predates
        // the message set used here, and a higher version still speaks 3
        // to a client that announced 3 (§4: the server replies with the
        // lower of the two).
        guard version >= SFTPCodec.protocolVersion else {
            close()
            throw .protocolViolation("the server speaks SFTP version \(version), below 3")
        }
        var byName: [String: [UInt8]] = [:]
        for item in extensions { byName[item.nameString] = item.data }
        let info = SFTPServerCapabilities(
            version: version,
            extensions: byName,
            supportsStatVFS: byName[SFTPCodec.statVFSExtensionName] != nil,
            supportsPosixRename: byName[SFTPCodec.posixRenameExtensionName] != nil)
        let completionError = state.withLock { state -> SFTPError? in
            if let closed = state.closed { return closed }
            state.serverInfo = info
            return nil
        }
        if let completionError { throw completionError }
        return info
    }

    /// Ends the session: the transport is closed (which for the real
    /// channel kills and reaps the ssh subprocess) and every suspended
    /// request resumes with `.cancelled`. Idempotent.
    public func close() {
        tearDown(with: .cancelled, closingTransport: true)
    }

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

    /// FSTAT (§8.3) on an open handle.
    public func fstat(handle: SFTPHandle) async throws(SFTPError) -> SFTPAttributes {
        try await attributesRequest { _ in .fstat(handle: handle.rawValue) }
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

    // MARK: - Request plumbing

    /// Sends one request and awaits its reply. Window admission, id
    /// allocation, continuation registration, the serialised write, and
    /// cancellation are sequenced so that a reply can never arrive to find
    /// no waiter, and a cancelled request's id is never recycled before
    /// its late reply lands.
    private func request(
        _ payload: (UInt32) -> SFTPPayload
    ) async throws(SFTPError) -> SFTPMessage {
        let ticket = try await acquireRequestSlot()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>) in
                let registered = state.withLock { state -> Bool in
                    if state.closed != nil {
                        return false
                    }
                    guard state.ids.register(ticket) else { return false }
                    state.inFlight[ticket.id] = (ticket, continuation)
                    return true
                }
                guard registered else {
                    // The slot was acquired and will never be used, nor its
                    // writer place.
                    let failure = state.withLock { state -> SFTPError in
                        state.unwrittenFrames -= 1
                        releaseWindowSlot(&state)
                        admitWaiters(&state)
                        return state.closed ?? SFTPError.cancelled
                    }
                    continuation.resume(returning: .failure(failure))
                    return
                }
                let frame = SFTPCodec.encodeFrame(
                    SFTPMessage(requestID: ticket.id, request: payload(ticket.id)))
                sendFrame(frame, reserved: true) { [self] error in failRequest(ticket, with: error) }
            }
        } onCancel: {
            cancelRequest(ticket)
        }
        return try result.get()
    }

    /// Suspends until the in-flight window admits another request, then
    /// allocates its id. FIFO: a burst of pipelined READs cannot starve a
    /// CLOSE queued behind them.
    private func acquireRequestSlot() async throws(SFTPError) -> SFTPRequestIDLedger.Ticket {
        if Task.isCancelled { throw .cancelled }
        if let closed = state.withLock({ $0.closed }) { throw closed }
        // Fast path: the window has room.
        let fastTicket = state.withLock { state -> SFTPRequestIDLedger.Ticket? in
            guard state.closed == nil, admits(state) else { return nil }
            state.windowUsed += 1
            state.unwrittenFrames += 1
            return state.ids.allocate()
        }
        if let fastTicket { return fastTicket }

        let token = state.withLock { state -> UInt64 in
            defer { state.nextWindowToken += 1 }
            return state.nextWindowToken
        }
        // The continuation's Bool says *how* it was resumed: true only
        // when the window admitted this waiter. A cancellation handler
        // resumes false, and only for a waiter still queued — admission
        // removes the waiter from the queue first, under the lock, so a
        // continuation is never resumed twice and an admitted slot is
        // never stranded by a late cancellation.
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Re-checked here: room may have opened since the fast path,
                // and a frame draining finds no waiter to admit until this
                // one is queued.
                let outcome = state.withLock { state -> Bool? in
                    guard state.closed == nil, !Task.isCancelled else { return false }
                    if admits(state) {
                        state.windowUsed += 1
                        state.unwrittenFrames += 1
                        return true
                    }
                    state.windowWaiters.append((token: token, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            state.withLock { state in
                if let index = state.windowWaiters.firstIndex(where: { $0.token == token }) {
                    state.windowWaiters.remove(at: index).continuation.resume(returning: false)
                }
            }
        }
        guard admitted else {
            if let closed = state.withLock({ $0.closed }) { throw closed }
            throw .cancelled
        }
        return state.withLock { $0.ids.allocate() }
    }

    /// The task running `request` was cancelled: resume its waiter with
    /// `.cancelled` and hold the id out of circulation until the server's
    /// late reply arrives (see the type's doc comment).
    private func cancelRequest(_ ticket: SFTPRequestIDLedger.Ticket) {
        let exhausted = state.withLock { state -> Bool in
            guard state.closed == nil else { return false }
            // Only if the entry is *this* allocation: with two transfers
            // sharing a session the id may already belong to someone else,
            // and resuming their continuation would cancel a request whose
            // frame is on the wire.
            if let entry = state.inFlight[ticket.id], entry.ticket == ticket {
                // Do not admit replacement work at the limit. Teardown runs
                // outside the lock because closing the transport can block.
                guard state.ids.retainedLateReplyCount < max(1, configuration.maxCancelledRequests)
                else { return true }
                state.inFlight[ticket.id] = nil
                state.ids.cancelledWhileInFlight(ticket)
                entry.continuation.resume(returning: .failure(.cancelled))
                if state.ids.retainedLateReplyCount >= max(1, configuration.maxCancelledRequests) {
                    return true
                }
                releaseWindowSlot(&state)
            } else {
                // Either cancelled between slot acquisition and
                // registration — the registration gives the slot and the
                // id back — or cancelled after the request already
                // resolved, which owes nothing. The ledger tells those
                // apart; this handler cannot, because `inFlight` is empty
                // in both cases.
                state.ids.cancelledBeforeRegistration(ticket)
            }
            return false
        }
        if exhausted {
            tearDown(
                with: .protocolViolation("too many cancelled requests awaiting replies"),
                closingTransport: true)
        }
    }

    /// A request failed before its reply could arrive (the write itself
    /// failed): resume its waiter, free the slot and the id.
    private func failRequest(_ ticket: SFTPRequestIDLedger.Ticket, with error: SFTPError) {
        state.withLock { state in
            guard let entry = state.inFlight[ticket.id], entry.ticket == ticket else { return }
            state.inFlight[ticket.id] = nil
            releaseWindowSlot(&state)
            state.ids.resolved(ticket)
            entry.continuation.resume(returning: .failure(error))
        }
    }

    /// Gives a slot back: to the next FIFO waiter if there is one and the
    /// writer queue has a place for it — the slot passes to it and
    /// `windowUsed` does not move — otherwise to the window.
    private func releaseWindowSlot(_ state: inout State) {
        guard state.closed == nil else { return }
        guard !state.windowWaiters.isEmpty,
            state.unwrittenFrames < configuration.maxInFlightRequests
        else {
            state.windowUsed -= 1
            return
        }
        state.unwrittenFrames += 1
        state.windowWaiters.removeFirst().continuation.resume(returning: true)
    }

    /// Room for one more sender: in the window, and in the writer queue.
    private func admits(_ state: State) -> Bool {
        state.closed == nil
            && state.ids.retainedLateReplyCount < max(1, configuration.maxCancelledRequests)
            && state.windowUsed < configuration.maxInFlightRequests
            && state.unwrittenFrames < configuration.maxInFlightRequests
    }

    /// After a frame leaves the writer queue: admits the waiters the queue
    /// was holding back.
    private func admitWaiters(_ state: inout State) {
        while !state.windowWaiters.isEmpty, admits(state) {
            state.windowUsed += 1
            state.unwrittenFrames += 1
            state.windowWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Queues `frame` behind every frame sent before it; `onFailure` runs on
    /// the writer queue if the transport refuses it. Bounded: a request's
    /// place was reserved when `acquireRequestSlot` admitted it (`reserved`);
    /// the handshake, which precedes the window, takes one here.
    private func sendFrame(
        _ frame: [UInt8], reserved: Bool, onFailure: @escaping @Sendable (SFTPError) -> Void
    ) {
        if !reserved { state.withLock { $0.unwrittenFrames += 1 } }
        writerQueue.async { [self, transport] in
            defer {
                state.withLock { state in
                    state.unwrittenFrames -= 1
                    admitWaiters(&state)
                }
            }
            // `withUnsafeBytes` rethrows untyped; the typed error is carried out.
            let failure = frame.withUnsafeBytes { bytes -> SFTPTransportError? in
                do throws(SFTPTransportError) {
                    try transport.write(bytes)
                    return nil
                } catch {
                    return error
                }
            }
            if let failure { onFailure(.transport(failure)) }
        }
    }

    private func finishHandshake(_ result: Result<SFTPMessage, SFTPError>) {
        state.withLock { state in
            guard let handshake = state.handshake else { return }
            state.handshake = nil
            handshake.resume(returning: result)
        }
    }

    /// Ends everything: every in-flight request, window waiter and a
    /// pending handshake resume with `error`, and later operations fail
    /// with it. The transport is closed unless the reader itself is
    /// tearing down after a transport failure (closing it again is
    /// harmless but pointless).
    private func tearDown(with error: SFTPError, closingTransport: Bool) {
        let drained = state.withLock { state -> (
            handshakes: [CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>],
            requests: [CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>],
            waiters: [CheckedContinuation<Bool, Never>],
            alreadyClosed: Bool
        ) in
            if state.closed != nil {
                return ([], [], [], true)
            }
            state.closed = error
            let handshakes = state.handshake.map { [$0] } ?? []
            state.handshake = nil
            let requests = state.inFlight.values.map(\.continuation)
            state.inFlight.removeAll()
            state.ids = SFTPRequestIDLedger()
            let waiters = state.windowWaiters.map { $0.continuation }
            state.windowWaiters.removeAll()
            state.windowUsed = 0
            return (handshakes, requests, waiters, false)
        }
        guard !drained.alreadyClosed else { return }
        if closingTransport { transport.close() }
        for handshake in drained.handshakes { handshake.resume(returning: .failure(error)) }
        for request in drained.requests { request.resume(returning: .failure(error)) }
        for waiter in drained.waiters { waiter.resume(returning: false) }
    }

    // MARK: - Reader loop

    /// Runs on the dedicated reader thread: frame in, dispatch, repeat.
    /// Any failure — EOF, a transport error, an undecodable frame, a reply
    /// to an unknown id — ends the session, because after any of them the
    /// byte stream can no longer be trusted to align with requests.
    private func readerLoop() {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        while true {
            do {
                guard try readExact(&lengthBytes) else {
                    tearDown(with: .transport(.connectionLost), closingTransport: false)
                    return
                }
                let length = (UInt32(lengthBytes[0]) << 24) | (UInt32(lengthBytes[1]) << 16)
                    | (UInt32(lengthBytes[2]) << 8) | UInt32(lengthBytes[3])
                let frameLength = try SFTPCodec.validateFrameLength(length)
                var frame = [UInt8](repeating: 0, count: frameLength)
                guard try readExact(&frame) else {
                    tearDown(with: .transport(.connectionLost), closingTransport: false)
                    return
                }
                let message = try SFTPCodec.decodeFrame(frame)
                dispatch(message)
            } catch let error as SFTPCodecError {
                tearDown(
                    with: .protocolViolation("undecodable frame: \(error)"),
                    closingTransport: true)
                return
            } catch let error as SFTPTransportError {
                tearDown(with: .transport(error), closingTransport: false)
                return
            } catch let error as SFTPError {
                tearDown(with: error, closingTransport: true)
                return
            } catch {
                tearDown(with: .protocolViolation("\(error)"), closingTransport: true)
                return
            }
        }
    }

    /// Reads exactly `buffer.count` bytes. Returns false at EOF before
    /// the first byte of this read; EOF part-way through a frame is a
    /// lost connection, thrown as such.
    private func readExact(_ buffer: inout [UInt8]) throws -> Bool {
        var filled = 0
        while filled < buffer.count {
            let count = try buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return try transport.read(
                    into: UnsafeMutableRawBufferPointer(start: base + filled, count: raw.count - filled))
            }
            if count == 0 {
                if filled == 0 { return false }
                throw SFTPTransportError.connectionLost
            }
            filled += count
        }
        return true
    }

    /// Routes one decoded message to its waiter.
    private func dispatch(_ message: SFTPMessage) {
        if case .version = message.payload {
            finishHandshake(.success(message))
            return
        }
        let resolved = state.withLock { state -> (
            continuation: CheckedContinuation<Result<SFTPMessage, SFTPError>, Never>?,
            wasCancelled: Bool,
            unknown: Bool
        ) in
            if let entry = state.inFlight.removeValue(forKey: message.requestID) {
                releaseWindowSlot(&state)
                state.ids.resolved(entry.ticket)
                return (entry.continuation, false, false)
            }
            if state.ids.acceptLateReply(message.requestID) {
                // The late reply to a cancelled request: swallow it, and
                // only now is the id safe to recycle.
                return (nil, true, false)
            }
            return (nil, false, true)
        }
        if let continuation = resolved.continuation {
            continuation.resume(returning: .success(message))
        } else if resolved.unknown {
            tearDown(
                with: .protocolViolation(
                    "a reply arrived for request-id \(message.requestID), which nothing sent"),
                closingTransport: true)
        }
    }

    // MARK: - Response mapping

    private func attributesRequest(
        _ payload: @escaping (UInt32) -> SFTPPayload
    ) async throws(SFTPError) -> SFTPAttributes {
        let reply = try await request(payload)
        guard case .attrs(let attributes) = reply.payload else {
            throw unexpected(reply, wanted: "ATTRS")
        }
        return attributes
    }

    /// Voids a reply that should be STATUS-OK; any other STATUS is the
    /// server's definitive answer to the request.
    private func expectOK(_ reply: SFTPMessage) throws(SFTPError) {
        switch reply.payload {
        case .status(let status):
            if status.code == .ok { return }
            throw .server(status)
        default:
            throw unexpected(reply, wanted: "STATUS")
        }
    }

    private func unexpected(_ reply: SFTPMessage, wanted: String) -> SFTPError {
        // A STATUS payload here is the server declining the request —
        // surface it as the server's answer, not as framing trouble.
        if case .status(let status) = reply.payload {
            return .server(status)
        }
        return .protocolViolation("expected \(wanted), got message type \(reply.type)")
    }
}
