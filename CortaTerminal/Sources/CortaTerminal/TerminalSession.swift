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
/// **Fairness**: batches are fed in slices, and the reader leaves a real gap
/// while a render-path waiter is registered (`yieldToStateWaiters`) —
/// releasing the lock alone lets the reader win it back every time (a
/// `snapshot()` once waited ~490 ms). `TerminalSessionLockWaitTests`.
public final class TerminalSession: @unchecked Sendable {
    /// Per `read`; internal so lifecycle tests can feed exact boundaries.
    static let readChunkSize = 64 * 1024
    private static let batchByteCap = 1024 * 1024

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
    }

    private let state: Mutex<State>
    private let callbacks = Mutex(Callbacks())
    private let stopped = Mutex(false)
    private let started = Mutex(false)

    /// Test hook: a scripted byte source. Assign before `start()`.
    var readerSource: ReaderSource?
    /// How long `?2026` may gate presents — the one-second cap terminals
    /// commonly use; the core reads no configuration. Tests may shorten it
    /// before `start()`.
    var synchronizedOutputTimeout: Duration = .seconds(1)
    /// Serial: resizes apply in request order.
    private let resizeQueue = DispatchQueue(label: "dev.corta.terminal-session.resize")

    /// The newest requested size; older queued resizes are skipped.
    private let requestedResize = Mutex<(serial: UInt64, size: TerminalSize)?>(nil)

    /// Test hook: holds queued resize work open. Assign before the first
    /// `resize(to:)`.
    var resizeWorkGate: (@Sendable () -> Void)?
    private let syncTimeoutQueue = DispatchQueue(label: "dev.corta.terminal-session.sync-timeout")

    /// A FIFO with a head index: popping one chunk at a time keeps `bytes` an
    /// exact backlog for the back-pressure cap, in amortized O(1).
    private struct PendingWrites {
        var chunks: [[UInt8]] = []
        var head = 0
        var bytes = 0
        var isDraining = false

        mutating func push(_ chunk: [UInt8]) {
            chunks.append(chunk)
            bytes += chunk.count
        }

        mutating func pop() -> [UInt8]? {
            guard head < chunks.count else { return nil }
            let chunk = chunks[head]
            head += 1
            bytes -= chunk.count
            if head == chunks.count {
                chunks = []
                head = 0
            } else if head >= 64, head * 2 >= chunks.count {
                chunks.removeFirst(head)
                head = 0
            }
            return chunk
        }

        mutating func removeAll() {
            chunks = []
            head = 0
            bytes = 0
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

    /// Test hook: records outbound writes. Assign before the first `write`.
    var writerSink: (@Sendable ([UInt8]) throws -> Void)?

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

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ChildEnvironment.default(),
        size: TerminalSize = TerminalSize(),
        workingDirectory: String? = nil,
        scrollbackLimit: Int = Scrollback.defaultLimit,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity
    ) throws(PTYError) {
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
                        current.terminal.feed(slice)
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
                    if offset < batch.count {
                        yieldToStateWaiters()
                    }
                }
                // Fixed-format only (`SECURITY.md` §2.1); same queue as input.
                if !responses.isEmpty {
                    enqueueWrite(responses)
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

        if let exit = pty.waitForExit() {
            let callback = callbacks.withLock { state -> (@Sendable (ChildExit) -> Void)? in
                state.childExit = exit
                return state.onChildExit
            }
            callback?(exit)
        }
    }

    private var liveReaderSource: ReaderSource {
        ReaderSource(
            read: { [pty] in try pty.read(into: $0) },
            isReadable: { [pty] in
                // Any revents count; the read observes end of file.
                while true {
                    var descriptor = pollfd(
                        fd: pty.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 0)
                    if ready >= 0 { return descriptor.revents != 0 }
                    if errno != EINTR { return true }  // let the read report it
                }
            }
        )
    }

    /// Ends a `?2026` episode the child never closes, unless a later episode
    /// has begun.
    private func scheduleSynchronizedOutputTimeout(episode: Int) {
        let components = synchronizedOutputTimeout.components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        let deadline = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
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

    /// Applied to the grid, never written to the child's input, which is for
    /// keystrokes only (`SECURITY.md` §6).
    public enum TerminalStateCommand: Sendable {
        case clearScreen
        case clearHistory
        /// RIS: everything, scrollback included.
        case reset
    }

    public func apply(_ command: TerminalStateCommand) {
        state.withLock {
            switch command {
            case .clearScreen: $0.terminal.grid.clearScreen()
            case .clearHistory: $0.terminal.grid.clearScrollback()
            case .reset: $0.terminal.reset()
            }
        }
    }

    /// Lets a caller (a paste) tell "queued" from "dropped, child not reading"
    /// from "session gone".
    public enum WriteOutcome: Sendable, Equatable {
        /// Queued (or empty — nothing to queue).
        case accepted
        /// Dropped: the backlog was already over the cap.
        case backpressured
        case stopped
    }

    /// Keyboard input only — never PTY output (`SECURITY.md` §6). Enqueues and
    /// returns; a blocking `write(2)` measured 43 ms per MB once the PTY filled.
    @discardableResult
    public func write(_ bytes: [UInt8]) -> WriteOutcome {
        enqueueWrite(bytes)
    }

    /// One queue for input and replies keeps them ordered.
    @discardableResult
    private func enqueueWrite(_ bytes: [UInt8]) -> WriteOutcome {
        guard !bytes.isEmpty else { return .accepted }
        guard !stopped.withLock({ $0 }) else { return .stopped }
        var shouldSchedule = false
        let outcome = pendingWrites.withLock { pending -> WriteOutcome in
            guard pending.bytes <= Self.maxPendingWriteBytes else { return .backpressured }
            pending.push(bytes)
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

    /// A failed chunk is dropped, so a dead child empties the queue fast.
    /// Popped before writing, so a `stop()` mid-write cannot be observed twice.
    private func drainPendingWrites() {
        while true {
            guard !stopped.withLock({ $0 }) else {
                pendingWrites.withLock { pending in
                    pending.removeAll()
                    pending.isDraining = false
                }
                return
            }
            let chunk = pendingWrites.withLock { pending -> [UInt8]? in
                guard let chunk = pending.pop() else {
                    pending.isDraining = false
                    return nil
                }
                return chunk
            }
            guard let chunk else { return }
            if let writerSink {
                try? writerSink(chunk)
            } else {
                chunk.withUnsafeBytes { _ = try? pty.writeAll($0) }
            }
        }
    }

    /// Without a full `snapshot()`; read on every scroll and output batch.
    public var scrollbackTotalPushed: Int {
        state.withLock { $0.terminal.grid.scrollback.totalPushed }
    }

    public var scrollbackCount: Int {
        state.withLock { $0.terminal.grid.scrollback.count }
    }

    public var isBracketedPasteEnabled: Bool {
        state.withLock { $0.terminal.isBracketedPasteEnabled }
    }

    /// `.off` unless SGR encoding is on; both read under one lock.
    public var sgrMouseTrackingMode: MouseTrackingMode {
        state.withLock {
            $0.terminal.isSgrMouseEncodingEnabled ? $0.terminal.mouseTrackingMode : .off
        }
    }

    public var isSgrMouseEncodingEnabled: Bool {
        state.withLock { $0.terminal.isSgrMouseEncodingEnabled }
    }

    /// Can go false without the child's DECRST (timeout, exit).
    public var isSynchronizedOutputEnabled: Bool {
        registerStateWaiter { state.withLock { $0.terminal.isSynchronizedOutputEnabled } }
    }

    public var isFocusReportingEnabled: Bool {
        state.withLock { $0.terminal.isFocusReportingEnabled }
    }

    public var isNewLineModeEnabled: Bool {
        state.withLock { $0.terminal.isNewLineModeEnabled }
    }

    public var applicationCursorKeysEnabled: Bool {
        state.withLock { $0.terminal.applicationCursorKeysEnabled }
    }

    public var applicationKeypadEnabled: Bool {
        state.withLock { $0.terminal.applicationKeypadEnabled }
    }

    public var dynamicColors: DynamicColors {
        get { state.withLock { $0.terminal.dynamicColors } }
        set { state.withLock { $0.terminal.dynamicColors = newValue } }
    }

    public var indexedPalette: IndexedPalette {
        get { state.withLock { $0.terminal.indexedPalette } }
        set { state.withLock { $0.terminal.indexedPalette = newValue } }
    }

    /// Under one lock: a get-then-set would race the reader's OSC 4 writes and
    /// could drop an override.
    public func updateIndexedPaletteDefaults(
        to newDefaults: [(red: UInt8, green: UInt8, blue: UInt8)]
    ) {
        state.withLock { $0.terminal.indexedPalette.updateDefaults(to: newDefaults) }
    }

    public var specialColors: SpecialColors {
        get { state.withLock { $0.terminal.specialColors } }
        set { state.withLock { $0.terminal.specialColors = newValue } }
    }

    public var keyboardEnhancements: KeyboardEnhancementFlags {
        state.withLock { $0.terminal.keyboardEnhancements }
    }

    public func takeBell() -> Bool {
        state.withLock { $0.terminal.takeBell() }
    }

    public var windowTitle: String? {
        state.withLock { $0.terminal.windowTitle }
    }

    /// Always local, safe to spawn or restore from.
    public var workingDirectory: String? {
        state.withLock { $0.terminal.workingDirectory }
    }

    /// Informational only; never for spawning.
    public var remoteContext: RemoteContext? {
        state.withLock { $0.terminal.remoteContext }
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
        state.withLock { $0.terminal.workingDirectory } ?? pty.currentWorkingDirectory
    }

    public var isCommandRunning: Bool {
        state.withLock { $0.terminal.isCommandRunning }
    }

    public var hasShellIntegration: Bool {
        state.withLock { $0.terminal.hasShellIntegration }
    }

    public var promptEndPosition: (row: Int, column: Int)? {
        state.withLock { $0.terminal.promptEndPosition }
    }

    public var commandRecords: CommandRecordStore {
        state.withLock { $0.terminal.commandRecords }
    }

    public func clearCommandRecords() {
        state.withLock { $0.terminal.clearCommandRecords() }
    }

    public func takeFinishedCommand() -> Int? {
        state.withLock { $0.terminal.takeFinishedCommand() }
    }

    /// OSC 52; the app decides whether it reaches the pasteboard.
    public func takeClipboardCopy() -> String? {
        state.withLock { $0.terminal.takeClipboardCopy() }
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
                    var grid = current.terminal.grid
                    grid.resize(rows: Int(size.rows), columns: Int(size.columns))
                    // Set after, and even with rows and columns unchanged:
                    // a font change alters only the pixels.
                    grid.cellPixelHeight = size.cellPixelHeight
                    current.terminal.grid = grid
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
