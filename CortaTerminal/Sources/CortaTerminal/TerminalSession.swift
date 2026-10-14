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

import CortaPOSIX
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
    static let batchByteCap = 1024 * 1024
    public let pty: PTY

    struct State {
        var terminal: Terminal
        /// The `?2026` episode the recovery timeout was armed for, so a stale
        /// timer cannot end a later one.
        var synchronizedOutputEpisode = 0
    }

    struct Callbacks {
        var onOutput: (@Sendable () -> Void)?
        var onChildExit: (@Sendable (ProcessExit) -> Void)?
        /// Replayed to a callback installed after the exit.
        var childExit: ProcessExit?
        var ioFailure: IOFailure?
        var onIOFailure: (@Sendable (IOFailure) -> Void)?
    }

    let state: Mutex<State>
    let callbacks = Mutex(Callbacks())
    let stopped = Mutex(false)
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
        /// Arms the `?2026` timeout; unset, a dispatch timer after
        /// `synchronizedOutputTimeout`. Tests take the callback and fire it
        /// in the order they mean to check, without waiting it out.
        var scheduleSynchronizedOutputTimeout: (@Sendable (Duration, @escaping @Sendable () -> Void) -> Void)?
        /// How long a stopped session's process group has to leave after
        /// `SIGHUP` before it gets `SIGKILL`.
        var hangupGracePeriod: Duration = .seconds(10)
    }

    let readerSource: ReaderSource?
    /// `Seams.synchronizedOutputTimeout`.
    let synchronizedOutputTimeout: Duration
    /// `Seams.scheduleSynchronizedOutputTimeout`.
    let scheduleTimeout: (@Sendable (Duration, @escaping @Sendable () -> Void) -> Void)?
    /// `Seams.hangupGracePeriod`.
    let hangupGracePeriod: Duration
    /// Serial: resizes apply in request order.
    private let resizeQueue = DispatchQueue(label: "dev.corta.terminal-session.resize")

    /// The newest requested size; older queued resizes are skipped.
    private let requestedResize = Mutex<(serial: UInt64, size: TerminalSize)?>(nil)

    private let resizeWorkGate: (@Sendable () -> Void)?
    let syncTimeoutQueue = DispatchQueue(label: "dev.corta.terminal-session.sync-timeout")

    /// A FIFO with a head index: popping one chunk at a time keeps `bytes` an
    /// exact backlog for the back-pressure cap, in amortized O(1). A paste's
    /// chunks carry its id, so a cancel can take them out from among the
    /// keystrokes typed after them.
    struct PendingWrites {
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
        /// The paste the chunk being written belongs to, if any. Popping a
        /// paste's last chunk retires its `pastes` entry, but the child has
        /// not taken those bytes until the write returns — a paste is
        /// queued, in flight, or done, and this is the middle state.
        var inFlightPaste: UInt64?

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
            inFlightPaste = chunk.paste
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
    let pendingWrites = Mutex(PendingWrites())
    /// Serial: chunks reach the PTY in enqueue order.
    let writerQueue = DispatchQueue(label: "dev.corta.terminal-session.writer")

    /// A backlog past this means the child stopped reading (the PTY alone
    /// absorbs ~100 MB), so more input is dropped rather than buffered without
    /// bound. A chunk larger than the cap is accepted while the backlog is under
    /// it, so a paste goes through while the pipe drains at all.
    static let maxPendingWriteBytes = 4 * 1024 * 1024

    /// Per lock acquisition; ≈ 4 ms at the worst measured feed rate.
    static let feedLockSliceSize = 16 * 1024

    /// Query replies one read batch may queue. A reply can be several times
    /// its query (`ESC]4;0;?` is answered with an `rgb:` triple), so a 1 MB
    /// batch of queries queued about 7 MB at once — admitted whole, since the
    /// back-pressure cap is checked before a chunk, not inside it. Past this,
    /// a slice's replies are dropped whole, never cut mid-sequence: a flood of
    /// queries is not a program waiting for every answer.
    static let maxResponseBytesPerBatch = 64 * 1024

    let writerSink: (@Sendable ([UInt8]) throws -> Void)?

    /// Shared with the app's other sessions; charged after every slice and
    /// released when this session stops.
    let imageBudget: ImageMemoryBudget?
    private let compressionQueue = DispatchQueue(label: "Corta.scrollback.compression", qos: .utility)
    private let compressionScheduled = Mutex(false)

    func scheduleCompression() {
        let start = compressionScheduled.withLock { active in
            if active { return false }
            active = true
            return true
        }
        guard start else { return }
        compressionQueue.async { [weak self] in
            guard let self else { return }
            while !self.stopped.withLock({ $0 }) {
                guard let work = self.state.withLock({ $0.terminal.nextCompressionWork() }) else { break }
                let result = work.compress()
                self.state.withLock { $0.terminal.installCompression(result) }
                self.yieldToStateWaiters()
            }
            self.compressionScheduled.withLock { $0 = false }
            // Close the final feed / drain race without keeping an idle timer.
            if !self.stopped.withLock({ $0 }), self.state.withLock({ $0.terminal.hasCompressionWork }) {
                self.scheduleCompression()
            }
        }
    }
    /// The last figure reported, written under `state`'s lock.
    let reportedImageBytes = Mutex(0)

    /// Render-path callers waiting on `state`; bumped before blocking, so an
    /// over-count only costs the reader one gap.
    private let stateWaiters = Mutex(0)

    /// Leaves the lock uncontended long enough for a waiter to land: the
    /// reader's unlock → relock is shorter than a futex wake.
    func yieldToStateWaiters() {
        guard stateWaiters.withLock({ $0 }) > 0 else { return }
        Thread.sleep(forTimeInterval: 0.0001)
    }

    /// Not a `withLock`-shaped wrapper: `Mutex.withLock`'s `sending` closure
    /// does not forward through one.
    func registerStateWaiter<T>(_ body: () -> T) -> T {
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

    func reportIOFailure(_ error: any Error, operation: IOFailure.Operation) {
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
    public var onChildExit: (@Sendable (ProcessExit) -> Void)? {
        get { callbacks.withLock { $0.onChildExit } }
        set {
            let replay: ProcessExit? = callbacks.withLock { state in
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
        scheduleTimeout = seams.scheduleSynchronizedOutputTimeout
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
        if let imageBudget {
            state.withLock { current in
                current.terminal.imageAllowanceProvider = { [weak self] in
                    guard let self else { return 0 }
                    return imageBudget.allowance(for: ObjectIdentifier(self))
                }
            }
        }
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

    public enum ReaderPriority: Int, Sendable {
        case interactive = 0
        case background = 1
    }
    private let requestedReaderPriority = Atomic<Int>(ReaderPriority.interactive.rawValue)
    private let appliedReaderPriority = Atomic<Int>(ReaderPriority.interactive.rawValue)

    /// Only the reader changes its pthread QoS. Requests do not wake an idle PTY.
    public func setReaderPriority(_ priority: ReaderPriority) {
        requestedReaderPriority.store(priority.rawValue, ordering: .releasing)
    }
    public var readerPriority: ReaderPriority {
        ReaderPriority(rawValue: appliedReaderPriority.load(ordering: .acquiring)) ?? .interactive
    }
    func applyReaderPriority() {
        let requested = requestedReaderPriority.load(ordering: .acquiring)
        guard requested != appliedReaderPriority.load(ordering: .relaxed) else { return }
        let qos =
            requested == ReaderPriority.background.rawValue
            ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED
        if pthread_set_qos_class_self_np(qos, 0) == 0 {
            appliedReaderPriority.store(requested, ordering: .releasing)
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
            scheduleCompression()
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
