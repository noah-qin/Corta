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
    let transport: SFTPChannelTransport

    struct State {
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

    let state = Mutex(State())
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

    // MARK: - Request plumbing

    /// Sends one request and awaits its reply. Window admission, id
    /// allocation, continuation registration, the serialised write, and
    /// cancellation are sequenced so that a reply can never arrive to find
    /// no waiter, and a cancelled request's id is never recycled before
    /// its late reply lands.
    func request(
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
    func releaseWindowSlot(_ state: inout State) {
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

    func finishHandshake(_ result: Result<SFTPMessage, SFTPError>) {
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
    func tearDown(with error: SFTPError, closingTransport: Bool) {
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

}
