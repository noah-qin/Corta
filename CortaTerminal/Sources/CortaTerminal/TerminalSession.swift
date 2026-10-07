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

/// Owns a PTY and the terminal it feeds — the unit a viewport renders
/// (`DECISIONS.md` D07).
///
/// **Reading** runs on one dedicated `Thread` (`DECISIONS.md` D04,
/// `PERFORMANCE.md` §2.1), never a `Task`, which can be hopped or starved;
/// a batch is capped near 1 MB so a flood still reaches the stop check.
///
/// **Writing** only enqueues: one serial writer queue drains to the PTY, so
/// a keystroke never blocks behind a child that stopped reading, and query
/// replies share that queue to stay ordered with the user's input.
///
/// **Configure before start**: `init` does not start the reader, so the
/// callbacks are installed before any byte is read; an exit that happened
/// first is replayed to the callback.
///
/// **Snapshots** copy the `Grid` value under the reader's lock — O(1)
/// copy-on-write, paid lazily by the reader's next mutation while the
/// snapshot lives: one row for a write to the live screen (`ScreenLines`),
/// but the `batches` array and the whole tail arena, up to 256 rows × width,
/// for the next `Scrollback.push`. Once per snapshot, not per push — the
/// copy is the reader's own from then on — so the frame's snapshot is
/// released as soon as it is diffed; a search sweep or an export, which
/// need the grid longer, pay that copy once (`PERFORMANCE.md` §5.9).
///
/// **Fairness**: batches are fed in slices, and after every slice the reader
/// leaves a real gap while a waiter is registered (`yieldToStateWaiters`) —
/// releasing the lock alone lets the reader win it back every time (a
/// `snapshot()` once waited ~490 ms). Every accessor off the reader thread
/// registers, not only `snapshot()`: a frame reads the bell, the synchronized
/// output mode and the palette as well, and one unregistered read is enough
/// to stall it. `TerminalSessionLockWaitTests`.
public final class TerminalSession: @unchecked Sendable {
    /// A terminal I/O failure, without retaining input or output bytes.
    public struct IOFailure: Sendable, Equatable, CustomStringConvertible {
        public enum Operation: String, Sendable { case read, write }
        public let operation: Operation
        public let message: String
        public var description: String { "PTY \(operation.rawValue) failed: \(message)" }
    }
    /// Per `read`; internal so lifecycle tests can feed exact boundaries.
    static let readChunkSize = 64 * 1024
    private static let batchByteCap = 1024 * 1024
    /// How long an idle reader waits before looking again at whether the
    /// session stopped: `PTY.close()` defers its close to an in-flight call,
    /// and a child that ignores `SIGHUP` would otherwise never let one return.
    private static let stopCheckMilliseconds: Int32 = 250

    public let pty: PTY

    private struct State {
        var terminal: Terminal
        /// The `?2026` episode the recovery timeout was armed for, so a stale
        /// timer cannot end a later one.
        var synchronizedOutputEpisode = 0
    }

    private struct Callbacks {
        var onOutput: (@Sendable () -> Void)?
        var onChildExit: (@Sendable (ChildExit) -> Void)?
        /// Replayed to a callback installed after the exit.
        var childExit: ChildExit?
        var ioFailure: IOFailure?
        var onIOFailure: (@Sendable (IOFailure) -> Void)?
    }

    private let state: Mutex<State>
    private let callbacks = Mutex(Callbacks())
    private let stopped = Mutex(false)
    private let started = Mutex(false)

    /// Stand-ins for the PTY's two directions, a step every queued resize
    /// passes before it applies, and the `?2026` cap: how a caller sets exact
    /// chunk boundaries, holds a write backlog, opens the window between a
    /// resize's request and its commit, or waits out an abandoned
    /// synchronized update in less than a second. The app passes none.
    struct Seams {
        /// Replaces the PTY read.
        var readerSource: ReaderSource?
        /// Replaces the PTY write.
        var writerSink: (@Sendable ([UInt8]) throws -> Void)?
        /// Runs first in each queued resize, on the resize queue.
        var resizeWorkGate: (@Sendable () -> Void)?
        /// How long `?2026` may gate presents — the one-second cap terminals
        /// commonly use; the core reads no configuration.
        var synchronizedOutputTimeout: Duration = .seconds(1)
        /// How long a stopped session's process group has to leave after
        /// `SIGHUP` before it gets `SIGKILL`.
        var hangupGracePeriod: Duration = .seconds(10)
    }

    private let readerSource: ReaderSource?
    /// `Seams.synchronizedOutputTimeout`.
    private let synchronizedOutputTimeout: Duration
    /// `Seams.hangupGracePeriod`.
    private let hangupGracePeriod: Duration
    /// Serial: resizes apply in request order.
    private let resizeQueue = DispatchQueue(label: "dev.corta.terminal-session.resize")

    /// The newest requested size; older queued resizes are skipped.
    private let requestedResize = Mutex<(serial: UInt64, size: TerminalSize)?>(nil)

    private let resizeWorkGate: (@Sendable () -> Void)?
    private let syncTimeoutQueue = DispatchQueue(label: "dev.corta.terminal-session.sync-timeout")

    /// A FIFO with a head index: popping one chunk at a time keeps `bytes` an
    /// exact backlog for the back-pressure cap, in amortized O(1). A paste's
    /// chunks carry its id, so a cancel can take them out from among the
    /// keystrokes typed after them.
    private struct PendingWrites {
        struct Chunk {
            var bytes: [UInt8]
            var paste: UInt64?
        }

        /// A queued paste: how many of its chunks are still queued, whether
        /// one has reached the child, and what ends it there — `ESC[201~`
        /// for a bracketed one.
        struct Paste {
            var remaining: Int
            var started = false
            var closing: [UInt8]?
        }

        var chunks: [Chunk] = []
        var head = 0
        var bytes = 0
        var isDraining = false
        var pastes: [UInt64: Paste] = [:]
        var nextPasteID: UInt64 = 0
        /// A write returned `EIO`: the replica is closed, which on Darwin
        /// means the session leader has gone — its controlling-terminal
        /// reference alone keeps end of file away while it lives. Input is
        /// refused from then on, under this lock so none slips in after.
        var hungUp = false
        /// A chunk is being written: set from pop to the write's return. A
        /// write that blocks, on a child not reading, keeps it set.
        var writing = false

        mutating func push(_ chunk: [UInt8], paste: UInt64? = nil) {
            chunks.append(Chunk(bytes: chunk, paste: paste))
            bytes += chunk.count
        }

        mutating func pop() -> [UInt8]? {
            guard head < chunks.count else { return nil }
            let chunk = chunks[head]
            head += 1
            bytes -= chunk.bytes.count
            if let id = chunk.paste, var paste = pastes[id] {
                paste.remaining -= 1
                paste.started = true
                pastes[id] = paste.remaining > 0 ? paste : nil
            }
            if head == chunks.count {
                chunks = []
                head = 0
            } else if head >= 64, head * 2 >= chunks.count {
                chunks.removeFirst(head)
                head = 0
            }
            return chunk.bytes
        }

        /// Drops every queued paste chunk. A paste the child has started
        /// reading is closed in place of its first dropped chunk, so a
        /// bracketed paste never leaves the shell in paste mode.
        mutating func cancelPastes() -> Bool {
            guard !pastes.isEmpty else { return false }
            var kept: [Chunk] = []
            kept.reserveCapacity(chunks.count - head)
            var closed = Set<UInt64>()
            for chunk in chunks[head...] {
                guard let id = chunk.paste else {
                    kept.append(chunk)
                    continue
                }
                if let paste = pastes[id], paste.started, let closing = paste.closing,
                    closed.insert(id).inserted
                {
                    kept.append(Chunk(bytes: closing, paste: nil))
                }
            }
            chunks = kept
            head = 0
            bytes = kept.reduce(0) { $0 + $1.bytes.count }
            pastes = [:]
            return true
        }

        mutating func removeAll() {
            chunks = []
            head = 0
            bytes = 0
            pastes = [:]
        }
    }
    private let pendingWrites = Mutex(PendingWrites())
    /// Serial: chunks reach the PTY in enqueue order.
    private let writerQueue = DispatchQueue(label: "dev.corta.terminal-session.writer")

    /// A backlog past this means the child stopped reading (the PTY alone
    /// absorbs ~100 MB), so more input is dropped rather than buffered without
    /// bound. A chunk larger than the cap is accepted while the backlog is under
    /// it, so a paste goes through while the pipe drains at all.
    private static let maxPendingWriteBytes = 4 * 1024 * 1024

    /// Per lock acquisition; ≈ 4 ms at the worst measured feed rate.
    private static let feedLockSliceSize = 16 * 1024

    private let writerSink: (@Sendable ([UInt8]) throws -> Void)?

    /// Shared with the app's other sessions; charged after every slice and
    /// released when this session stops.
    private let imageBudget: ImageMemoryBudget?
    /// The last figure reported, written under `state`'s lock.
    private let reportedImageBytes = Mutex(0)

    /// Render-path callers waiting on `state`; bumped before blocking, so an
    /// over-count only costs the reader one gap.
    private let stateWaiters = Mutex(0)

    /// Leaves the lock uncontended long enough for a waiter to land: the
    /// reader's unlock → relock is shorter than a futex wake.
    private func yieldToStateWaiters() {
        guard stateWaiters.withLock({ $0 }) > 0 else { return }
        Thread.sleep(forTimeInterval: 0.0001)
    }

    /// Not a `withLock`-shaped wrapper: `Mutex.withLock`'s `sending` closure
    /// does not forward through one.
    private func registerStateWaiter<T>(_ body: () -> T) -> T {
        stateWaiters.withLock { $0 += 1 }
        defer { stateWaiters.withLock { $0 -= 1 } }
        return body()
    }

    /// On the reader thread; the caller hops if it needs to.
    public var onOutput: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.onOutput } }
        set { callbacks.withLock { $0.onOutput = newValue } }
    }

    /// Delivered once, outside locks; replayed to a late subscriber. A failed
    /// session rejects further input, but keeps its child/grid until the owner
    /// explicitly retries or closes it.
    public var onIOFailure: (@Sendable (IOFailure) -> Void)? {
        get { callbacks.withLock { $0.onIOFailure } }
        set {
            let replay = callbacks.withLock { current in
                current.onIOFailure = newValue
                return newValue == nil ? nil : current.ioFailure
            }
            if let replay { newValue?(replay) }
        }
    }

    public var ioFailure: IOFailure? { callbacks.withLock { $0.ioFailure } }

    private func reportIOFailure(_ error: any Error, operation: IOFailure.Operation) {
        guard !stopped.withLock({ $0 }) else { return }
        let failure = IOFailure(operation: operation, message: String(describing: error))
        let delivery = callbacks.withLock { current -> ((@Sendable (IOFailure) -> Void)?, Bool) in
            guard current.ioFailure == nil else { return (nil, false) }
            current.ioFailure = failure
            return (current.onIOFailure, true)
        }
        guard delivery.1 else { return }
        pendingWrites.withLock { $0.removeAll() }
        delivery.0?(failure)
    }

    /// On the reader thread, after the loop stops; an earlier exit is replayed
    /// on the installing thread.
    public var onChildExit: (@Sendable (ChildExit) -> Void)? {
        get { callbacks.withLock { $0.onChildExit } }
        set {
            let replay: ChildExit? = callbacks.withLock { state in
                state.onChildExit = newValue
                return newValue == nil ? nil : state.childExit
            }
            // Outside the lock: caller code may touch this session.
            if let replay { newValue?(replay) }
        }
    }

    public convenience init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ChildEnvironment.default(),
        size: TerminalSize = TerminalSize(),
        workingDirectory: String? = nil,
        scrollbackLimit: Int = Scrollback.defaultLimit,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity,
        imageBudget: ImageMemoryBudget? = nil
    ) throws(PTYError) {
        try self.init(
            executable: executable, arguments: arguments, environment: environment, size: size,
            workingDirectory: workingDirectory, scrollbackLimit: scrollbackLimit,
            commandHistoryLimit: commandHistoryLimit, imageBudget: imageBudget, seams: Seams())
    }

    init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ChildEnvironment.default(),
        size: TerminalSize = TerminalSize(),
        workingDirectory: String? = nil,
        scrollbackLimit: Int = Scrollback.defaultLimit,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity,
        imageBudget: ImageMemoryBudget? = nil,
        seams: Seams
    ) throws(PTYError) {
        self.imageBudget = imageBudget
        readerSource = seams.readerSource
        writerSink = seams.writerSink
        resizeWorkGate = seams.resizeWorkGate
        synchronizedOutputTimeout = seams.synchronizedOutputTimeout
        hangupGracePeriod = seams.hangupGracePeriod
        let pty = try PTY.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment,
            size: size,
            workingDirectory: workingDirectory
        )
        self.pty = pty
        var terminal = Terminal(
            rows: Int(size.rows), columns: Int(size.columns), scrollbackLimit: scrollbackLimit,
            commandHistoryLimit: commandHistoryLimit
        )
        terminal.grid.cellPixelHeight = size.cellPixelHeight
        terminal.grid.cellPixelWidth = size.cellPixelWidth
        self.state = Mutex(State(terminal: terminal))
    }

    deinit {
        // Not a teardown path: the reader retains this session until it stops.
        // Owners call `stop()`.
        stop()
    }

    /// Idempotent.
    public func start() {
        let shouldStart = started.withLock { already -> Bool in
            guard !already else { return false }
            already = true
            return true
        }
        guard shouldStart else { return }
        ReaderBox(session: self).start()
    }

    // MARK: - Reading (runs on `readerThread` only)

    fileprivate func runReaderLoop() {
        let source = readerSource ?? liveReaderSource
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.readChunkSize, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        var batch = [UInt8]()
        batch.reserveCapacity(Self.batchByteCap)

        while !stopped.withLock({ $0 }) {
            // Between batches too: a flood is mostly single-slice batches.
            yieldToStateWaiters()
            batch.removeAll(keepingCapacity: true)
            var reachedEOF = false

            while batch.count < Self.batchByteCap {
                let region = UnsafeMutableRawBufferPointer(start: buffer, count: Self.readChunkSize)
                let read: Int
                do {
                    read = try source.read(region)
                } catch {
                    reportIOFailure(error, operation: .read)
                    reachedEOF = true
                    break
                }
                if read == 0 {
                    reachedEOF = true
                    break
                }
                batch.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: read))
                if read < Self.readChunkSize {
                    break
                }
                // Ask readiness rather than block: an exact chunk-multiple burst
                // would otherwise sit unapplied until the child speaks again.
                if !source.isReadable() { break }
            }

            if !batch.isEmpty {
                // Under the lock, in slices, so a snapshot or resize never waits
                // behind a whole batch.
                var responses: [UInt8] = []
                var episode: Int?
                var offset = 0
                while offset < batch.count {
                    let end = min(offset + Self.feedLockSliceSize, batch.count)
                    let slice = batch[offset..<end]
                    let applied = state.withLock { current -> (responses: [UInt8], episode: Int?) in
                        let episodeBefore = current.terminal.synchronizedOutputEpisode
                        // Only a slice that can start or end an APC (`ESC _`,
                        // `ESC \`) can store an image; others skip the shared lock.
                        if let imageBudget, slice.contains(0x5F) || slice.contains(0x5C) {
                            current.terminal.imageByteAllowance =
                                imageBudget.allowance(for: ObjectIdentifier(self))
                        }
                        current.terminal.feed(slice)
                        reportImageBytes(current.terminal)
                        let sliceResponses = current.terminal.takeOutput()
                        // Rising edges, so DECRST+BSU in one batch arms a fresh timeout.
                        // A repeated BSU does not extend it, or a child that never sends
                        // ESU could stall presentation forever.
                        let episodeAfter = current.terminal.synchronizedOutputEpisode
                        guard episodeAfter != episodeBefore else { return (sliceResponses, nil) }
                        current.synchronizedOutputEpisode = episodeAfter
                        return (sliceResponses, episodeAfter)
                    }
                    responses.append(contentsOf: applied.responses)
                    if let newEpisode = applied.episode { episode = newEpisode }
                    offset = end
                    // After the last slice too: the next batch's first slice is
                    // one `read(2)` away, sooner than a waiter's wake, so a flood
                    // of one-slice batches would never leave a gap.
                    yieldToStateWaiters()
                }
                // Fixed-format only (`SECURITY.md` §2.1); same queue as input.
                if !responses.isEmpty {
                    enqueueWrite([responses])
                }
                if let episode {
                    scheduleSynchronizedOutputTimeout(episode: episode)
                }
                callbacks.withLock { $0.onOutput }?()
            }

            if reachedEOF { break }
        }

        // A dead child never ends `?2026`; end it here so withheld output
        // draws.
        let clearedSync = state.withLock { current -> Bool in
            guard current.terminal.isSynchronizedOutputEnabled else { return false }
            current.terminal.endSynchronizedOutput()
            return true
        }
        if clearedSync {
            callbacks.withLock { $0.onOutput }?()
        }

        // An I/O fault is not child exit. Report it immediately rather than
        // park here for ten seconds and silently lose the only reader.
        guard ioFailure == nil else { return }
        var exit = pty.waitForExit(timeout: hangupGracePeriod)
        if exit == nil, !stopped.withLock({ $0 }) {
            // End of file, and the child lives on: it gave up its terminal
            // (`TIOCNOTTY`) and closed it. Nothing it does reaches this pane
            // again, and no exit is coming to say so — offer recovery.
            reportIOFailure(PTYError.ioFailed(code: ENXIO), operation: .read)
            return
        }
        if exit == nil, stopped.withLock({ $0 }) {
            // Closed, and the group ignored `SIGHUP` (`trap '' HUP`, a daemon
            // that kept the terminal): closing a pane stops what was in it
            // (`SECURITY.md` §4.4). Left alone it ran on with no terminal,
            // and nothing was left to reap it once it did exit. Only this
            // group: a job the shell put in its own is not this pane's to end.
            pty.signalProcessGroup(SIGKILL)
            exit = pty.waitForExit(timeout: .seconds(2))
        }
        if let exit {
            let callback = callbacks.withLock { state -> (@Sendable (ChildExit) -> Void)? in
                state.childExit = exit
                return state.onChildExit
            }
            callback?(exit)
        }
    }

    private var liveReaderSource: ReaderSource {
        ReaderSource(
            read: { [pty] buffer in
                // Bounded, not a bare blocking read: after `stop()` the timed
                // wait throws `.closed`, and the descriptor is released even if
                // the child never speaks or hangs up.
                while true {
                    if try pty.waitUntilReadable(timeoutMilliseconds: Self.stopCheckMilliseconds) {
                        return try pty.read(into: buffer)
                    }
                }
            },
            isReadable: { [pty] in
                // Any revents count; the read observes end of file.
                (try? pty.waitUntilReadable(timeoutMilliseconds: 0)) ?? true
            }
        )
    }

    /// Ends a `?2026` episode the child never closes, unless a later episode
    /// has begun.
    private func scheduleSynchronizedOutputTimeout(episode: Int) {
        let deadline = DispatchTime.now() + synchronizedOutputTimeout.dispatchInterval
        syncTimeoutQueue.asyncAfter(deadline: deadline) { [self] in
            let ended = state.withLock { current -> Bool in
                guard current.synchronizedOutputEpisode == episode,
                      current.terminal.isSynchronizedOutputEnabled
                else { return false }
                current.terminal.endSynchronizedOutput()
                return true
            }
            if ended {
                callbacks.withLock { $0.onOutput }?()
            }
        }
    }

    // MARK: - Public API (any thread)

    /// Safe every frame; registered as a waiter.
    public func snapshot() -> Grid {
        registerStateWaiter { state.withLock { $0.terminal.grid } }
    }

    /// One coherent read for the native input-source overlay, with the grid
    /// and shell phase from the same parse batch. No command-history copy.
    public func inputLineSnapshot() -> (grid: Grid, hasIntegration: Bool, promptRow: Int?) {
        registerStateWaiter {
            state.withLock {
                ($0.terminal.grid, $0.terminal.hasShellIntegration, $0.terminal.inputPromptRow)
            }
        }
    }

    /// Applied to the grid, never written to the child's input, which is for
    /// keystrokes only (`SECURITY.md` §6).
    public enum TerminalStateCommand: Sendable {
        case clearScreen
        case clearHistory
        /// RIS: everything, scrollback included.
        case reset
    }

    public func apply(_ command: TerminalStateCommand) {
        registerStateWaiter {
            state.withLock {
                switch command {
                case .clearScreen: $0.terminal.clearScreen()
                case .clearHistory: $0.terminal.grid.clearScrollback()
                case .reset: $0.terminal.reset()
                }
                reportImageBytes($0.terminal)
            }
        }
    }

    /// Under `state`'s lock. Not after `stop()`: a last slice racing it would
    /// charge the shared budget again for a pane that is gone.
    private func reportImageBytes(_ terminal: Terminal) {
        guard let imageBudget else { return }
        // Most slices hold no image: skip the shared lock unless the figure moved.
        let bytes = terminal.retainedImageBytes
        guard bytes != reportedImageBytes.withLock({ $0 }), !stopped.withLock({ $0 }) else { return }
        reportedImageBytes.withLock { $0 = bytes }
        imageBudget.report(bytes, for: ObjectIdentifier(self))
    }

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
        enqueueWrite([bytes])
    }

    /// Every chunk or none, under one backlog check. Admitted while the
    /// backlog is under the cap, however large — the cap pushes back on a
    /// child that stopped reading. A paste goes through `write(paste:closing:)`
    /// instead, whose cut is closed rather than left in paste mode.
    @discardableResult
    public func write(chunks: [[UInt8]]) -> WriteOutcome {
        enqueueWrite(chunks)
    }

    /// A paste: as `write(chunks:)`, but its queued chunks can be dropped
    /// (`interruptPendingPaste`). `closing` is what ends it for the child —
    /// `ESC[201~` for a bracketed paste — and is sent in place of the rest
    /// when a cancel cuts one the child has started reading; it should be
    /// the paste's last chunk on its own, so a cut never splits it.
    @discardableResult
    public func write(paste chunks: [[UInt8]], closing: [UInt8]?) -> WriteOutcome {
        enqueueWrite(chunks, kind: .paste(closing: closing))
    }

    /// A paste is still queued for the child.
    var hasPendingPaste: Bool {
        pendingWrites.withLock { !$0.pastes.isEmpty }
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
    /// foreground group now, as the terminal would deliver it.
    public func interruptPendingPaste() -> PasteInterrupt {
        let (cancelled, writing) = pendingWrites.withLock { pending in
            (pending.cancelPastes(), pending.writing)
        }
        guard cancelled else { return PasteInterrupt() }
        guard writing, writerSink == nil, pty.interruptForegroundGroupIfSignalsEnabled() else {
            return PasteInterrupt(cancelledPaste: true)
        }
        return PasteInterrupt(cancelledPaste: true, signalled: true)
    }

    private enum WriteKind {
        case input
        case paste(closing: [UInt8]?)
    }

    /// One queue for input and replies keeps them ordered.
    @discardableResult
    private func enqueueWrite(_ chunks: [[UInt8]], kind: WriteKind = .input) -> WriteOutcome {
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
                    return nil
                }
                pending.writing = true
                return chunk
            }
            guard let chunk else { return }
            defer { pendingWrites.withLock { $0.writing = false } }
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

    /// Without a full `snapshot()`; read on every scroll and output batch.
    public var scrollbackTotalPushed: Int {
        registerStateWaiter { state.withLock { $0.terminal.grid.scrollback.totalPushed } }
    }

    public var scrollbackCount: Int {
        registerStateWaiter { state.withLock { $0.terminal.grid.scrollback.count } }
    }

    public var isBracketedPasteEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isBracketedPasteEnabled } }
    }

    /// `.off` unless SGR encoding is on; both read under one lock.
    public var sgrMouseTrackingMode: MouseTrackingMode {
        registerStateWaiter {
            state.withLock {
                $0.terminal.isSgrMouseEncodingEnabled ? $0.terminal.mouseTrackingMode : .off
            }
        }
    }

    public var isSgrMouseEncodingEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isSgrMouseEncodingEnabled } }
    }

    /// Can go false without the child's DECRST (timeout, exit).
    public var isSynchronizedOutputEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isSynchronizedOutputEnabled } }
    }

    public var isFocusReportingEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isFocusReportingEnabled } }
    }

    public var isNewLineModeEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isNewLineModeEnabled } }
    }

    /// `Terminal.wheelSendsArrowKeys`, read per wheel event.
    public var wheelSendsArrowKeys: Bool {
        registerStateWaiter { state.withLock { $0.terminal.wheelSendsArrowKeys } }
    }

    public var applicationCursorKeysEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.applicationCursorKeysEnabled } }
    }

    public var applicationKeypadEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.applicationKeypadEnabled } }
    }

    public var dynamicColors: DynamicColors {
        get { registerStateWaiter { state.withLock { $0.terminal.dynamicColors } } }
        set { registerStateWaiter { state.withLock { $0.terminal.dynamicColors = newValue } } }
    }

    public var indexedPalette: IndexedPalette {
        get { registerStateWaiter { state.withLock { $0.terminal.indexedPalette } } }
        set { registerStateWaiter { state.withLock { $0.terminal.indexedPalette = newValue } } }
    }

    /// Under one lock: a get-then-set would race the reader's OSC 4 writes and
    /// could drop an override.
    public func updateIndexedPaletteDefaults(
        to newDefaults: [(red: UInt8, green: UInt8, blue: UInt8)]
    ) {
        registerStateWaiter { state.withLock { $0.terminal.indexedPalette.updateDefaults(to: newDefaults) } }
    }

    public var specialColors: SpecialColors {
        get { registerStateWaiter { state.withLock { $0.terminal.specialColors } } }
        set { registerStateWaiter { state.withLock { $0.terminal.specialColors = newValue } } }
    }

    public var keyboardEnhancements: KeyboardEnhancementFlags {
        registerStateWaiter { state.withLock { $0.terminal.keyboardEnhancements } }
    }

    public func takeBell() -> Bool {
        registerStateWaiter { state.withLock { $0.terminal.takeBell() } }
    }

    public var windowTitle: String? {
        registerStateWaiter { state.withLock { $0.terminal.windowTitle } }
    }

    /// Always local, safe to spawn or restore from.
    public var workingDirectory: String? {
        registerStateWaiter { state.withLock { $0.terminal.workingDirectory } }
    }

    /// Informational only; never for spawning.
    public var remoteContext: RemoteContext? {
        registerStateWaiter { state.withLock { $0.terminal.remoteContext } }
    }

    /// A command other than the shell is running — what a close confirmation
    /// asks (`PTY.hasForegroundJob`).
    public var hasForegroundJob: Bool { pty.hasForegroundJob }

    public var foregroundProcessName: String? { pty.foregroundProcessName }

    /// Shell included, for a title bar.
    public var activeProcessName: String? { pty.activeProcessName }

    /// OSC 7 first (the shell's own answer); else the kernel's for the
    /// foreground group, since stock macOS zsh sends OSC 7 only to Terminal.app.
    public var currentDirectory: String? {
        registerStateWaiter { state.withLock { $0.terminal.workingDirectory } } ?? pty.currentWorkingDirectory
    }

    public var isCommandRunning: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isCommandRunning } }
    }

    public var hasShellIntegration: Bool {
        registerStateWaiter { state.withLock { $0.terminal.hasShellIntegration } }
    }

    public var promptEndPosition: (row: Int, column: Int)? {
        registerStateWaiter { state.withLock { $0.terminal.promptEndPosition } }
    }

    public var directoryCompletion: DirectoryCompletion? {
        registerStateWaiter { state.withLock { $0.terminal.directoryCompletion } }
    }

    public var commandRecords: CommandRecordStore {
        registerStateWaiter { state.withLock { $0.terminal.commandRecords } }
    }

    public func clearCommandRecords() {
        registerStateWaiter { state.withLock { $0.terminal.clearCommandRecords() } }
    }

    public func takeFinishedCommand() -> Int? {
        registerStateWaiter { state.withLock { $0.terminal.takeFinishedCommand() } }
    }

    /// OSC 52; the app decides whether it reaches the pasteboard.
    public func takeClipboardCopy() -> String? {
        registerStateWaiter { state.withLock { $0.terminal.takeClipboardCopy() } }
    }

    /// The child must never see (`TIOCGWINSZ`/`SIGWINCH`) a size the grid has
    /// not adopted, or its redraw is parsed into old-size cells — lasting, on the
    /// alternate screen, which is never reflowed. So on `resizeQueue`, in order:
    /// the reflow commits under the reader's lock, then `TIOCSWINSZ` signals.
    ///
    /// That delays `SIGWINCH` by one reflow (~108 ms at 100k lines), so queued
    /// requests coalesce to the latest; the work stays off the caller's thread.
    /// Bytes written before the signal may land at the new width — bounded by
    /// one batch, and repainted by the child. `onOutput` then wakes a redraw.
    public func resize(to size: TerminalSize) {
        let serial = requestedResize.withLock { requested -> UInt64 in
            let next = (requested?.serial ?? 0) + 1
            requested = (serial: next, size: size)
            return next
        }
        resizeQueue.async { [self] in
            resizeWorkGate?()
            guard requestedResize.withLock({ $0?.serial == serial }) else { return }
            // Registered: `SIGWINCH` waits on this commit.
            registerStateWaiter {
                state.withLock { current in
                    current.terminal.resize(rows: Int(size.rows), columns: Int(size.columns))
                    // Set after, and even with rows and columns unchanged:
                    // a font change alters only the pixels.
                    current.terminal.grid.cellPixelHeight = size.cellPixelHeight
                    current.terminal.grid.cellPixelWidth = size.cellPixelWidth
                }
            }
            try? pty.resize(to: size)
            callbacks.withLock { $0.onOutput }?()
        }
    }

    /// Idempotent. Pending input is discarded; a drain parked in `write(2)`
    /// fails with `EIO` once the child dies, then sees `stopped`.
    public func stop() {
        let wasStopped = stopped.withLock { already -> Bool in
            let was = already
            already = true
            return was
        }
        guard !wasStopped else { return }
        pendingWrites.withLock { $0.removeAll() }
        // The grid stays readable, but its images no longer count against
        // panes that are still live. Under `state`, so a slice the reader is
        // applying cannot report again after this.
        if let imageBudget {
            // As a waiter, or the reader holds the lock through the rest of
            // its batch and closing a flooding pane stalls the main thread.
            registerStateWaiter {
                state.withLock { _ in imageBudget.release(ObjectIdentifier(self)) }
            }
        }
        pty.terminate()
        pty.close()
    }
}

/// What the reader loop drains: a blocking read plus a readiness check.
/// Tests inject a scripted source so exact chunk boundaries are
/// deterministic; production reads the PTY and asks a zero-timeout `poll`
/// whether more bytes are immediately available.
struct ReaderSource {
    /// Blocking read of up to `buffer.count` bytes; 0 at end of file.
    var read: (UnsafeMutableRawBufferPointer) throws -> Int
    /// Whether a read issued right now would return without blocking.
    var isReadable: () -> Bool
}

/// Starts the reader thread.
private final class ReaderBox: NSObject {
    let session: TerminalSession

    init(session: TerminalSession) {
        self.session = session
    }

    func start() {
        let thread = Thread { [session] in
            session.runReaderLoop()
        }
        thread.name = "com.corta.terminal.reader"
        thread.stackSize = 1 << 20
        // Not the default QoS: this thread gates output → frame and must keep
        // draining under contention (`PERFORMANCE.md` §2.1).
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
