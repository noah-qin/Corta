import Darwin
import Dispatch
import Foundation
import Synchronization

/// Owns a PTY and the terminal it feeds — the unit a viewport renders
/// (`DESIGN.md` §2.4) and the boundary the AppKit shell reaches across to get
/// pixels on screen.
///
/// Threading (`DESIGN.md` §2.2, §2.6, `PERFORMANCE.md` §2.1): reading and
/// parsing run on one dedicated `Thread`, started by `start()`, never on the
/// main thread and never inside a `Task` on the default executor — a `Task`
/// can be hopped off its thread or starved by other work on the same
/// executor, and draining the PTY must never depend on either. A single parse
/// batch is capped at roughly 1 MB before the loop re-checks whether it
/// should stop; without the cap a sustained flood (`yes`) would never yield.
///
/// Writing is symmetric: `write` only enqueues, and one serial writer queue
/// drains pending chunks to the PTY in FIFO order, so the caller (usually
/// the main thread, on a keystroke) never blocks in `write(2)` behind a
/// child that has stopped reading. Keyboard input and the parser's query
/// replies share the one queue, which is what keeps the two ordered with
/// respect to each other.
///
/// Lifecycle is configure-before-start: `init` does not start the reader, so
/// `onOutput`/`onChildExit` (both guarded by a lock) are always installed
/// before any byte is read, and a child that exits before its exit callback
/// is installed has that exit replayed the moment one is.
///
/// The renderer never touches `terminal` directly. It calls `snapshot()`,
/// which copies the `Grid` value out from under the same lock the reader
/// thread feeds against. This is copy-on-snapshot, not double buffering:
/// `Grid` is a plain value type over `ContiguousArray`, so the copy itself
/// is O(1) copy-on-write. The reader thread pays the actual copy cost
/// lazily, the next time it mutates a row the snapshot still shares; that
/// cost is bounded by one row, not the whole grid, because rows are the
/// unit `Line` mutation copies.
///
/// A parse batch *is* fed under that lock — the grid may never be mutated
/// from two threads, and a resize commit must not interleave with a feed —
/// but in slices (`feedLockSliceSize`), and the reader leaves a real gap
/// between batches/slices whenever a render-path waiter is registered
/// (`yieldToStateWaiters`): releasing an `os_unfair_lock` wakes a waiter,
/// but the reader's unlock → relock window is far shorter than the wake, so
/// slicing alone starves the waiter across whole batches (measured: 27 of
/// 4682 `snapshot()` calls waited >10 ms, max ~490 ms, slice holds
/// meanwhile ≤ 2.5 ms). With the gap, `corta-bench` measures p99 ≈ 0.001 ms
/// / max ≈ 0.24 ms; the pre-fix whole-batch hold was p99 ≈ 1–43 ms, max ≈
/// 77–269 ms. Regression: `TerminalSessionLockWaitTests`.
public final class TerminalSession: @unchecked Sendable {
    /// Bytes read per `PTY.read` call before the batch is re-checked against
    /// the cap. Small enough to keep the cap accurate, large enough that the
    /// syscall count under a flood stays sane. Internal, not private, so the
    /// lifecycle tests can feed exact chunk boundaries.
    static let readChunkSize = 64 * 1024
    /// `PERFORMANCE.md` §2.1: "roughly 1 MB".
    private static let batchByteCap = 1024 * 1024

    public let pty: PTY

    private struct State {
        var terminal: Terminal
        /// The newest `?2026` episode the recovery timeout was armed for —
        /// mirrored from the core's rising-edge counter, so a stale timer
        /// can't cut a later episode short.
        var synchronizedOutputEpisode = 0
    }

    private struct Callbacks {
        var onOutput: (@Sendable () -> Void)?
        var onChildExit: (@Sendable (ChildExit) -> Void)?
        /// The exit the reader loop already observed, kept so a callback
        /// installed afterwards still receives it.
        var childExit: ChildExit?
    }

    private let state: Mutex<State>
    private let callbacks = Mutex(Callbacks())
    private let stopped = Mutex(false)
    private let started = Mutex(false)

    /// Test hook: replaces the PTY as the reader loop's byte source so chunk
    /// boundaries are deterministic. Must be assigned before `start()`; the
    /// read happens on the reader thread, ordered after the assignment by
    /// `Thread.start`.
    var readerSource: ReaderSource?
    /// How long a `?2026` episode may gate presents before the session ends
    /// it core-side. Fixed rather than configurable: the core package reads
    /// no configuration (`DESIGN.md` §2.4), and one second is the safety cap
    /// terminals that implement the timeout commonly use. A `var` so tests
    /// can shorten it; assign before `start()`, like `readerSource`.
    var synchronizedOutputTimeout: Duration = .seconds(1)
    /// Serial, not concurrent: two resizes must apply in the order they
    /// were requested, never race to decide which size "wins".
    private let resizeQueue = DispatchQueue(label: "dev.corta.terminal-session.resize")

    /// The newest size handed to `resize(to:)`. A queued resize block
    /// applies its size only while it is still this one — see `resize(to:)`.
    private let requestedResize = Mutex<(serial: UInt64, size: TerminalSize)?>(nil)

    /// Test hook, run on `resizeQueue` before a resize block does its work:
    /// lets a test hold queued resize work while it observes what the child
    /// does in the window between a resize request and its application (the
    /// grid/SIGWINCH ordering regression). Assign before the first
    /// `resize(to:)`; not safe to reassign afterwards.
    var resizeWorkGate: (@Sendable () -> Void)?
    private let syncTimeoutQueue = DispatchQueue(label: "dev.corta.terminal-session.sync-timeout")

    /// Pending outbound chunks for the writer queue (P01). A hand-rolled
    /// FIFO with a head index: popping one chunk at a time keeps `bytes` an
    /// accurate count of the unwritten backlog (the back-pressure cap
    /// applies to it), and the index keeps the pop amortized O(1) where
    /// `removeFirst` would make draining a large backlog O(n²).
    /// `isDraining` says a drain block is already scheduled/running, so
    /// enqueue schedules at most one.
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
    /// Serial: two chunks must reach the pty in enqueue order, never
    /// interleaved by concurrent `write(2)` calls.
    private let writerQueue = DispatchQueue(label: "dev.corta.terminal-session.writer")

    /// Back-pressure cap on queued-but-unwritten input. A backlog past this
    /// means the child has stopped reading (a pty's input side alone absorbs
    /// on the order of 100 MB before stalling), so further keystrokes would
    /// never be acted on anyway; they are dropped rather than buffered
    /// without bound, and the caller is never blocked. A single chunk larger
    /// than the cap is still accepted when the backlog is under it, so a
    /// large paste goes through whenever the pipe is draining at all.
    private static let maxPendingWriteBytes = 4 * 1024 * 1024

    /// Largest slice of a parse batch fed per lock acquisition — see the
    /// type's header comment (P02). At the measured worst observed feed rate
    /// (a scroll-heavy `yes` flood, ~269 ms per 1 MB batch) one slice holds
    /// the lock ≈ 4 ms; ordinary batches are far below that.
    private static let feedLockSliceSize = 16 * 1024

    /// Test hook: replaces the PTY as the writer queue's byte sink so tests
    /// can gate and record outbound writes deterministically. Must be
    /// assigned before the first `write`; read on the writer queue, ordered
    /// after the assignment by `DispatchQueue.async`.
    var writerSink: (@Sendable ([UInt8]) throws -> Void)?

    /// Approximate count of threads waiting to acquire `state` via the
    /// render-path entry points (`snapshot`, the per-frame mode reads, the
    /// resize commit). The reader's feed-slice loop checks it between slices
    /// and leaves a gap while anyone is registered — see the loop for why
    /// merely releasing the lock is not enough. Approximate because it is
    /// bumped *before* the waiter blocks; a momentarily over-counted value
    /// only costs the reader one gap.
    private let stateWaiters = Mutex(0)

    /// If a render-path waiter is registered on `state`, leave the lock
    /// uncontended long enough for it to land: releasing an
    /// `os_unfair_lock` wakes the waiter, but the reader's unlock → relock
    /// window (~ns between slices, ~tens of µs across an inter-batch read)
    /// is shorter than a futex wake (~µs) plus scheduling, so the reader
    /// otherwise wins the lock back at every boundary and the waiter
    /// starves. Called by the reader loop only.
    private func yieldToStateWaiters() {
        guard stateWaiters.withLock({ $0 }) > 0 else { return }
        Thread.sleep(forTimeInterval: 0.0001)
    }

    /// Registers a `state` waiter for the duration of the closure; the
    /// render-path entry points wrap their `state.withLock` in this so a
    /// feed in progress leaves them a gap. Inline rather than a
    /// `withLock`-shaped helper because `Mutex.withLock`'s `sending`
    /// closure signature does not forward through a wrapper cleanly.
    private func registerStateWaiter<T>(_ body: () -> T) -> T {
        stateWaiters.withLock { $0 += 1 }
        defer { stateWaiters.withLock { $0 -= 1 } }
        return body()
    }

    /// Called from the reader thread whenever a batch has been applied, so
    /// the shell can schedule a redraw. Never called on the main thread by
    /// this type — the shell is responsible for hopping if it needs to.
    public var onOutput: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.onOutput } }
        set { callbacks.withLock { $0.onOutput = newValue } }
    }

    /// Called from the reader thread once the child has exited and the
    /// reader loop has stopped. If the child already exited before the
    /// callback was installed, the stored exit is replayed to the new
    /// callback immediately, on the installing thread.
    public var onChildExit: (@Sendable (ChildExit) -> Void)? {
        get { callbacks.withLock { $0.onChildExit } }
        set {
            let replay: ChildExit? = callbacks.withLock { state in
                state.onChildExit = newValue
                return newValue == nil ? nil : state.childExit
            }
            // Outside the lock: the callback is caller code and may touch
            // this session again.
            if let replay { newValue?(replay) }
        }
    }

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ChildEnvironment.default(),
        size: TerminalSize = TerminalSize(),
        workingDirectory: String? = nil,
        scrollbackLimit: Int = Scrollback.defaultLimit
    ) throws(PTYError) {
        let pty = try PTY.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment,
            size: size,
            workingDirectory: workingDirectory
        )
        self.pty = pty
        self.state = Mutex(State(
            terminal: Terminal(
                rows: Int(size.rows), columns: Int(size.columns), scrollbackLimit: scrollbackLimit
            )
        ))
        // The reader is NOT started here: `onOutput`/`onChildExit` must be
        // installed first, and only `start()` may begin draining.
    }

    deinit {
        // Not a teardown path to rely on: the reader thread's closure
        // strongly retains this session, so deinit only runs once the loop
        // has already stopped. Owners must call `stop()`.
        stop()
    }

    /// Starts the reader thread. Call after installing `onOutput` /
    /// `onChildExit`; idempotent, later calls are ignored.
    public func start() {
        let shouldStart = started.withLock { already -> Bool in
            guard !already else { return false }
            already = true
            return true
        }
        guard shouldStart else { return }
        // A dedicated `Thread`, not a `Task` (`DESIGN.md` §2.2, §2.6): a task
        // can be hopped or starved by unrelated work on the same executor,
        // and draining the PTY must never depend on either.
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
            // Between batches, not just between slices: a `yes` flood
            // mostly produces single-slice batches, and the inter-batch
            // read phase (~tens of µs when the pty buffer stays full) is
            // shorter than a futex wake, so a `snapshot()` waiter loses the
            // re-acquire race at every boundary and starves for hundreds of
            // ms — measured 27/4682 calls over 10 ms, max ~490 ms. The gap
            // costs nothing when nobody is waiting (one atomic read).
            yieldToStateWaiters()
            batch.removeAll(keepingCapacity: true)
            var reachedEOF = false

            // Drain what is immediately available, capped at ~1 MB, then
            // yield by applying the batch and looping back to a blocking
            // read. This is what keeps one enormous burst from starving the
            // stop check (`PERFORMANCE.md` §2.1).
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
                    // Nothing more was immediately available; apply now
                    // rather than blocking for more while holding a batch.
                    break
                }
                // A full chunk says nothing about what remains queued —
                // looping here into another blocking read would hold the
                // unapplied batch until the child speaks again, which for an
                // exact chunk-multiple burst can be forever. Ask readiness
                // instead and apply when nothing more is pending.
                if !source.isReadable() { break }
            }

            if !batch.isEmpty {
                // Feed under the lock — the grid may only ever be mutated
                // there, and a resize commit must not interleave with a
                // feed — but in slices, releasing the lock between them, so
                // a `snapshot()` or a queued resize never waits behind a
                // whole batch (P02). A resize may now commit between two
                // slices of one batch; that is the same bound the batch cap
                // already gave (one in-flight batch), just finer-grained.
                var responses: [UInt8] = []
                var episode: Int?
                var offset = 0
                while offset < batch.count {
                    let end = min(offset + Self.feedLockSliceSize, batch.count)
                    // A fresh `[UInt8]`, not an `ArraySlice`: the parser's
                    // ASCII fast path only applies to the contiguous-array
                    // overload, and a 16 KB memcpy is noise next to a parse.
                    let slice = Array(batch[offset..<end])
                    let applied = state.withLock { current -> (responses: [UInt8], episode: Int?) in
                        let episodeBefore = current.terminal.synchronizedOutputEpisode
                        current.terminal.feed(slice)
                        let sliceResponses = current.terminal.takeOutput()
                        // The core counts BSU rising edges, so a DECRST+BSU
                        // pair in one batch — a compliant renderer's normal
                        // frame loop — arms a fresh timeout for the new
                        // episode; a bool compare would read on → on and let
                        // the old episode's timer cut the new one short. A
                        // repeated BSU inside an episode does not extend the
                        // bounded wait — extending on every BSU is exactly
                        // what a child that never sends ESU would use to
                        // stall presentation forever.
                        let episodeAfter = current.terminal.synchronizedOutputEpisode
                        guard episodeAfter != episodeBefore else { return (sliceResponses, nil) }
                        current.synchronizedOutputEpisode = episodeAfter
                        return (sliceResponses, episodeAfter)
                    }
                    responses.append(contentsOf: applied.responses)
                    if let newEpisode = applied.episode { episode = newEpisode }
                    offset = end
                    // Same starvation within a multi-slice batch — see the
                    // per-batch call for the mechanism.
                    if offset < batch.count {
                        yieldToStateWaiters()
                    }
                }
                // Query responses (M2.2). Fixed-format bytes only — never
                // attacker-supplied text (`SECURITY.md` §2.1). They take the
                // same queue as keyboard input so a reply stays ordered with
                // respect to the input the user typed around it.
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

        // A child that is gone (or hung up) can never send the DECRST that
        // ends `?2026`; end the episode from this side and signal output so
        // whatever the episode withheld still draws.
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

    /// The PTY itself as a `ReaderSource`: blocking reads, with readiness
    /// answered by a zero-timeout `poll`.
    private var liveReaderSource: ReaderSource {
        ReaderSource(
            read: { [pty] in try pty.read(into: $0) },
            isReadable: { [pty] in
                // Any revents (POLLIN, but also POLLERR/POLLHUP) count:
                // the following read is what observes end of file.
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

    /// `?2026` recovery (S03): the child promises a DECRST to end each
    /// episode; if it never arrives, the shell's present gate would hold
    /// forever. After `synchronizedOutputTimeout` the episode is ended
    /// core-side and output is signalled, so the shell — which latched that
    /// it owes a present when the gate first held — draws the withheld
    /// frames on the next vsync. The episode number guards against a stale
    /// timer ending a later episode whose DECRST is still coming.
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

    /// A copy of the current grid. Cheap (`Grid` is a value type); safe to
    /// call from the render thread every frame. Registered as a `state`
    /// waiter so a feed in progress leaves the caller a gap — see
    /// `registerStateWaiter`.
    public func snapshot() -> Grid {
        registerStateWaiter { state.withLock { $0.terminal.grid } }
    }

    /// U11 — the three terminal-state commands, each with one meaning.
    ///
    /// They are applied to the grid directly rather than by writing an escape
    /// sequence to the child: writing to the child's *input* is how the shell
    /// would see them as typed characters, and `SECURITY.md` §6 keeps that
    /// channel for keyboard input only. A user asking Corta to clear its own
    /// screen is asking Corta, not the program.
    public enum TerminalStateCommand: Sendable {
        /// Erase the visible screen, keep the scrollback, cursor home.
        case clearScreen
        /// Discard the scrollback, keep the visible screen.
        case clearHistory
        /// RIS: modes, screens, tab stops, title, cursor, screen *and*
        /// scrollback — everything a fresh terminal would not have.
        case reset
    }

    /// Applies one of the three. Returns nothing: the caller redraws from the
    /// next `snapshot()` like any other change.
    public func apply(_ command: TerminalStateCommand) {
        state.withLock {
            switch command {
            case .clearScreen: $0.terminal.grid.clearScreen()
            case .clearHistory: $0.terminal.grid.clearScrollback()
            case .reset: $0.terminal.reset()
            }
        }
    }

    /// Queues bytes for the child. Never routes attacker-controlled PTY
    /// output back into this call (`SECURITY.md` §6) — it is for keyboard
    /// input only.
    ///
    /// P01: the call only enqueues; a serial writer queue performs the
    /// actual `write(2)` in FIFO order, so the caller (a keystroke on the
    /// main thread) never blocks behind a child that has stopped reading —
    /// measured at 43 ms for a single 1 MB write once the pty's input side
    /// fills, and unbounded beyond that (`corta-bench`, "write
    /// backpressure"). The queue is bounded (`maxPendingWriteBytes`); when
    /// the backlog exceeds the cap the child is provably not reading and new
    /// input is dropped rather than buffered without bound — the alternative
    /// is the whole UI freezing on a wedged child. `stop()` cancels anything
    /// still pending.
    public func write(_ bytes: [UInt8]) {
        enqueueWrite(bytes)
    }

    /// FIFO enqueue shared by keyboard input and the parser's query replies;
    /// taking one path through one queue is what keeps the two ordered with
    /// respect to each other.
    private func enqueueWrite(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard !stopped.withLock({ $0 }) else { return }
        let shouldSchedule = pendingWrites.withLock { pending -> Bool in
            guard pending.bytes <= Self.maxPendingWriteBytes else { return false }
            pending.push(bytes)
            guard !pending.isDraining else { return false }
            pending.isDraining = true
            return true
        }
        if shouldSchedule {
            writerQueue.async { [self] in drainPendingWrites() }
        }
    }

    /// Runs on `writerQueue` only. Drains until the queue is empty or the
    /// session has stopped; a failed chunk (child gone, descriptor closed)
    /// is dropped and the loop continues, so a dead child empties the queue
    /// fast instead of retrying forever. Chunks are popped before being
    /// written, so a `stop()` clearing the queue mid-write cannot make a
    /// later pop observe a queue it already emptied.
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

    /// Whether the child has enabled bracketed paste (`?2004`, M2.6).
    public var isBracketedPasteEnabled: Bool {
        state.withLock { $0.terminal.isBracketedPasteEnabled }
    }

    /// Whether the child has asked for SGR-encoded mouse reports (`?1006`,
    /// M2.7).
    public var isSgrMouseEncodingEnabled: Bool {
        state.withLock { $0.terminal.isSgrMouseEncodingEnabled }
    }

    /// Whether synchronized output is active (`?2026`, M4.3). While true the
    /// shell must present no frame; when it goes false, present once. An
    /// episode is bounded by `synchronizedOutputTimeout` and by child exit —
    /// the mode can go false without the child's DECRST.
    public var isSynchronizedOutputEnabled: Bool {
        // The present gate is read every frame; register like `snapshot()`.
        registerStateWaiter { state.withLock { $0.terminal.isSynchronizedOutputEnabled } }
    }

    /// Whether the child has asked to be told about focus changes (`?1004`,
    /// M6.7).
    public var isFocusReportingEnabled: Bool {
        state.withLock { $0.terminal.isFocusReportingEnabled }
    }

    /// Whether LNM is set (`CSI 20 h`). The Return key sends CR LF while it
    /// is, rather than a bare CR.
    public var isNewLineModeEnabled: Bool {
        state.withLock { $0.terminal.isNewLineModeEnabled }
    }

    /// Whether DECCKM is set (`CSI ? 1 h`). The cursor keys send their SS3
    /// (application) forms while it is.
    public var applicationCursorKeysEnabled: Bool {
        state.withLock { $0.terminal.applicationCursorKeysEnabled }
    }

    /// Whether DECKPAM is set (`ESC =`). The numeric keypad sends its SS3
    /// (application) forms while it is (U04).
    public var applicationKeypadEnabled: Bool {
        state.withLock { $0.terminal.applicationKeypadEnabled }
    }

    /// The colours OSC 10/11/12 report and set (M6.6). The app seeds these
    /// from its palette at startup so a query answers with what is drawn.
    public var dynamicColors: DynamicColors {
        get { state.withLock { $0.terminal.dynamicColors } }
        set { state.withLock { $0.terminal.dynamicColors = newValue } }
    }

    /// The kitty keyboard protocol flags in force (`CSI > flags u`, M6.9).
    public var keyboardEnhancements: KeyboardEnhancementFlags {
        state.withLock { $0.terminal.keyboardEnhancements }
    }

    /// Consumes a pending BEL (M4.8): true at most once per bell.
    public func takeBell() -> Bool {
        state.withLock { $0.terminal.takeBell() }
    }

    /// The window title set by the child via OSC 0/2 (M2.8). Set-only — the
    /// title query is never answered (`SECURITY.md` §2.2).
    public var windowTitle: String? {
        state.withLock { $0.terminal.windowTitle }
    }

    /// The working directory reported via OSC 7 (M2.8). Reports that name a
    /// remote host (`file://remote/path` from an `ssh` session) are dropped
    /// at parse time — see `Performer.setWorkingDirectory` — so this is
    /// always a local path, safe to spawn or restore from.
    public var workingDirectory: String? {
        state.withLock { $0.terminal.workingDirectory }
    }

    /// Whether a command other than the shell itself is running here — what
    /// a close confirmation asks before it throws away a half-finished job
    /// (M7.5). Derived from the pty's foreground process group; see
    /// `PTY.hasForegroundJob`.
    public var hasForegroundJob: Bool { pty.hasForegroundJob }

    /// The name of that command, when it can be read.
    public var foregroundProcessName: String? { pty.foregroundProcessName }

    /// What owns the terminal right now, shell included — for a title bar
    /// rather than for a confirmation dialog. See `PTY.activeProcessName`.
    public var activeProcessName: String? { pty.activeProcessName }

    /// Where this session is, by whichever route answers.
    ///
    /// OSC 7 first: a shell that reports its directory is reporting the one
    /// it believes it is in, which is the right answer when a program has
    /// changed directory internally. A remote host's report never reaches
    /// here — the parser drops it — so the fallback also covers panes whose
    /// shell is on another machine. That fallback is the kernel's answer for
    /// the foreground process group, because a stock macOS zsh sends no
    /// OSC 7 to anything but Terminal.app (`PTY.currentWorkingDirectory`).
    public var currentDirectory: String? {
        state.withLock { $0.terminal.workingDirectory } ?? pty.currentWorkingDirectory
    }

    /// Whether the shell reports a command running via OSC 133 (M7.2).
    public var isCommandRunning: Bool {
        state.withLock { $0.terminal.isCommandRunning }
    }

    /// Whether this session's shell emits OSC 133 at all. The app falls back
    /// to its keystroke heuristic when it does not.
    public var hasShellIntegration: Bool {
        state.withLock { $0.terminal.hasShellIntegration }
    }

    /// Consumes the exit status of a command that just finished (OSC 133 D).
    public func takeFinishedCommand() -> Int? {
        state.withLock { $0.terminal.takeFinishedCommand() }
    }

    /// Consumes text the child asked to place on the system clipboard via
    /// OSC 52 (M7.11). Whether it actually reaches the pasteboard is the
    /// app's decision.
    public func takeClipboardCopy() -> String? {
        state.withLock { $0.terminal.takeClipboardCopy() }
    }

    /// Ordering contract (P03; user-reported corruption: claude/kimi TUIs
    /// redrew garbled after a window drag): the child must never observe —
    /// via `TIOCGWINSZ`/`SIGWINCH` — a size the grid has not adopted yet.
    /// Otherwise its new-size redraw is parsed into old-size cells, and the
    /// damage outlives the gap: the alternate screen is resized, never
    /// reflowed (M4.2), so a mis-parsed full-screen redraw there stays
    /// garbled until the child happens to repaint those cells. Both halves
    /// therefore run on `resizeQueue`, in order: the grid reflow commits
    /// first — under the same lock the reader thread parses against, so no
    /// batch can be parsed between the commit and the signal — and only
    /// then does `TIOCSWINSZ` let the kernel raise `SIGWINCH`.
    ///
    /// The price is `SIGWINCH` promptness: the signal now waits on the
    /// reflow, measured at ~108 ms for a full 100k-line scrollback
    /// (`corta-bench`), and a drag can hand sizes over faster than that.
    /// Queued requests therefore coalesce to the latest — an obsolete size
    /// neither reflows the grid nor signals the child — bounding the added
    /// latency at one reflow instead of the whole backlog. The work stays
    /// off the calling thread regardless: running the reflow synchronously
    /// would stall the main thread by that same ~108 ms worst case. Bytes
    /// the child wrote *before* the signal may still be parsed after the
    /// commit and land at the new width; that direction is bounded by one
    /// in-flight batch and is overwritten by the child's post-`SIGWINCH`
    /// redraw, unlike the corruption this ordering prevents. The block ends
    /// with `onOutput` — the same wake a parse batch uses — so the reflowed
    /// grid is drawn even when the child stays quiet after a resize.
    public func resize(to size: TerminalSize) {
        let serial = requestedResize.withLock { requested -> UInt64 in
            let next = (requested?.serial ?? 0) + 1
            requested = (serial: next, size: size)
            return next
        }
        resizeQueue.async { [self] in
            resizeWorkGate?()
            guard requestedResize.withLock({ $0?.serial == serial }) else { return }
            // Registered: a drag during an output flood must not starve
            // behind feed slices — the reflow commit is what `SIGWINCH`
            // waits on.
            registerStateWaiter {
                state.withLock { current in
                    var grid = current.terminal.grid
                    grid.resize(rows: Int(size.rows), columns: Int(size.columns))
                    current.terminal.grid = grid
                }
            }
            try? pty.resize(to: size)
            callbacks.withLock { $0.onOutput }?()
        }
    }

    /// Stops the reader thread and hangs up the child. Idempotent. Pending
    /// outbound writes are discarded: the child is gone, so queued input has
    /// no one left to read it. A drain currently parked in `write(2)` is
    /// released by `terminate()` — the child's death closes the replica and
    /// the write fails with `EIO` — and then observes `stopped`.
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

/// Keeps the `Thread(target:selector:)` entry point out of `TerminalSession`
/// itself so the session's public surface stays free of `@objc`.
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
        // Left at the default QoS, this thread can be deprioritised under
        // CPU contention exactly like any other background thread — but it
        // gates the output → wake → frame chain and must never stop
        // draining regardless of what else is running (`PERFORMANCE.md`
        // §2.1: "never stop draining the PTY"). `.userInitiated` asks the
        // scheduler to treat it accordingly.
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
