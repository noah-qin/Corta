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

/// Input to the child: the write queue, pastes and their interruption. Any thread.
extension TerminalSession {
    /// Lets a caller (a paste) tell "queued" from "dropped, child not reading"
    /// from "session gone".
    public enum WriteOutcome: Sendable, Equatable {
        /// Queued (or empty — nothing to queue).
        case accepted
        /// Dropped: the backlog was already over the cap.
        case backpressured
        case stopped
        case failed
    }

    /// Keyboard input only — never PTY output (`SECURITY.md` §6). Enqueues and
    /// returns; a blocking `write(2)` measured 43 ms per MB once the PTY filled.
    @discardableResult
    public func write(_ bytes: [UInt8]) -> WriteOutcome {
        setReaderPriority(.interactive)
        return enqueueWrite([bytes])
    }

    /// A fixed focus protocol report, not user input. Preserve the reader's
    /// visibility policy instead of promoting a hidden session indefinitely.
    /// Shares input's bounded queue and ordering, including backpressure.
    @discardableResult
    public func writeFocusReport(isFocused: Bool) -> WriteOutcome {
        enqueueWrite([[0x1B, 0x5B, isFocused ? 0x49 : 0x4F]])
    }

    /// Every chunk or none, under one backlog check. Admitted while the
    /// backlog is under the cap, however large — the cap pushes back on a
    /// child that stopped reading. A paste goes through `write(paste:closing:)`
    /// instead, whose cut is closed rather than left in paste mode.
    @discardableResult
    public func write(chunks: [[UInt8]]) -> WriteOutcome {
        setReaderPriority(.interactive)
        return enqueueWrite(chunks)
    }

    /// A paste: as `write(chunks:)`, but its queued chunks can be dropped
    /// (`interruptPendingPaste`). `closing` is what ends it for the child —
    /// `ESC[201~` for a bracketed paste — and is sent in place of the rest
    /// when a cancel cuts one the child has started reading; it should be
    /// the paste's last chunk on its own, so a cut never splits it.
    @discardableResult
    public func write(paste chunks: [[UInt8]], closing: [UInt8]?) -> WriteOutcome {
        setReaderPriority(.interactive)
        return enqueueWrite(chunks, kind: .paste(closing: closing))
    }

    /// A paste is still queued for the child.
    var hasPendingPaste: Bool {
        pendingWrites.withLock { !$0.pastes.isEmpty }
    }

    /// A paste's chunk is being written and has not returned.
    var isPasteInFlight: Bool {
        pendingWrites.withLock { $0.writing && $0.inFlightPaste != nil }
    }

    /// What Ctrl-C did to a paste still queued ahead of it.
    public struct PasteInterrupt: Sendable, Equatable {
        /// Queued paste chunks were dropped.
        public var cancelledPaste = false
        /// The interrupt was delivered as `SIGINT`; do not also write `^C`.
        public var signalled = false
    }

    /// Ctrl-C with a paste queued: drops what is still queued of every paste,
    /// keeping keystrokes typed after it — before, Ctrl-C waited behind the
    /// whole paste, or was refused by the back-pressure cap. When a chunk is
    /// still being written — blocked on a child that stopped reading — a `^C`
    /// queued behind it would wait for that write too; if the line discipline
    /// would turn `^C` into `SIGINT` (`ISIG`), the signal goes to the
    /// foreground group now, as the terminal would deliver it. That holds
    /// for a paste's last chunk too: popped, nothing of it is queued any
    /// more, but until its write returns the child has not read it and a
    /// `^C` behind it waits just the same.
    public func interruptPendingPaste() -> PasteInterrupt {
        let (cancelled, writing, pasteInFlight) = pendingWrites.withLock { pending in
            (pending.cancelPastes(), pending.writing, pending.inFlightPaste != nil)
        }
        guard cancelled || (writing && pasteInFlight) else { return PasteInterrupt() }
        guard writing, writerSink == nil, pty.interruptForegroundGroupIfSignalsEnabled() else {
            return PasteInterrupt(cancelledPaste: cancelled)
        }
        return PasteInterrupt(cancelledPaste: cancelled, signalled: true)
    }

    enum WriteKind {
        case input
        case paste(closing: [UInt8]?)
    }

    /// One queue for input and replies keeps them ordered.
    @discardableResult
    func enqueueWrite(_ chunks: [[UInt8]], kind: WriteKind = .input) -> WriteOutcome {
        let chunks = chunks.filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return .accepted }
        guard !stopped.withLock({ $0 }) else { return .stopped }
        guard ioFailure == nil else { return .failed }
        guard callbacks.withLock({ $0.childExit == nil }) else { return .stopped }
        var shouldSchedule = false
        let outcome = pendingWrites.withLock { pending -> WriteOutcome in
            guard !pending.hungUp else { return .stopped }
            guard pending.bytes <= Self.maxPendingWriteBytes else { return .backpressured }
            var pasteID: UInt64?
            if case .paste(let closing) = kind {
                pending.nextPasteID &+= 1
                pasteID = pending.nextPasteID
                pending.pastes[pending.nextPasteID] = PendingWrites.Paste(
                    remaining: chunks.count, closing: closing)
            }
            for chunk in chunks { pending.push(chunk, paste: pasteID) }
            if !pending.isDraining {
                pending.isDraining = true
                shouldSchedule = true
            }
            return .accepted
        }
        if shouldSchedule {
            writerQueue.async { [self] in drainPendingWrites() }
        }
        return outcome
    }

    /// Returns once every write queued so far has been written or dropped:
    /// one drain empties the queue. For tests, so "never written" is a fact
    /// rather than a wait that happened to be long enough.
    func waitForQueuedWrites() { writerQueue.sync {} }

    /// A failed chunk fails the session; later chunks must not silently follow
    /// a partial write (particularly a bracketed paste).
    /// Popped before writing, so a `stop()` mid-write cannot be observed twice.
    private func drainPendingWrites() {
        while true {
            guard !stopped.withLock({ $0 }), ioFailure == nil else {
                pendingWrites.withLock { pending in
                    pending.removeAll()
                    pending.isDraining = false
                }
                return
            }
            let chunk = pendingWrites.withLock { pending -> [UInt8]? in
                guard let chunk = pending.pop() else {
                    pending.isDraining = false
                    pending.writing = false
                    pending.inFlightPaste = nil
                    return nil
                }
                pending.writing = true
                return chunk
            }
            guard let chunk else { return }
            defer {
                pendingWrites.withLock { pending in
                    pending.writing = false
                    pending.inFlightPaste = nil
                }
            }
            do {
                if let writerSink {
                    try writerSink(chunk)
                } else {
                    try chunk.withUnsafeBytes { _ = try pty.writeAll($0) }
                }
            } catch PTYError.ioFailed(code: EIO) {
                // Darwin's answer to a write once the last replica holder
                // closed it: the child is gone, or left its terminal. An
                // exit, not a fault — the child's own exit report follows,
                // and input from now on is refused as for a stopped session.
                noteHangup()
            } catch {
                reportIOFailure(error, operation: .write)
            }
        }
    }

    /// Nothing holds the replica any more: queued input has nowhere to go.
    private func noteHangup() {
        pendingWrites.withLock { pending in
            pending.hungUp = true
            pending.removeAll()
        }
    }
}
