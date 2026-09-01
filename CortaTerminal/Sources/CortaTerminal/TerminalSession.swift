import Dispatch
import Foundation
import Synchronization

/// Owns a PTY and the terminal it feeds — the unit a viewport renders
/// (`DESIGN.md` §2.4) and the boundary the AppKit shell reaches across to get
/// pixels on screen.
///
/// Threading (`DESIGN.md` §2.2, §2.6, `PERFORMANCE.md` §2.1): reading and
/// parsing run on one dedicated `Thread`, started here, never on the main
/// thread and never inside a `Task` on the default executor — a `Task` can be
/// hopped off its thread or starved by other work on the same executor, and
/// draining the PTY must never depend on either. A single parse batch is
/// capped at roughly 1 MB before the loop re-checks whether it should stop;
/// without a cap a sustained flood (`yes`) would never yield.
///
/// The renderer never touches `terminal` directly. It calls `snapshot()`,
/// which copies the `Grid` value out from under a short-held lock. This is
/// copy-on-snapshot, not double buffering: `Grid` is a plain value type over
/// `ContiguousArray`, so the copy itself is O(1) copy-on-write, and the lock
/// is held only for that copy — never for a parse batch, never for a frame.
/// The reader thread pays the actual copy cost lazily, the next time it
/// mutates a row the snapshot still shares; that cost is bounded by one row,
/// not the whole grid, because rows are the unit `Line` mutation copies.
public final class TerminalSession: @unchecked Sendable {
    /// Bytes read per `PTY.read` call before the batch is re-checked against
    /// the cap. Small enough to keep the cap accurate, large enough that the
    /// syscall count under a flood stays sane.
    private static let readChunkSize = 64 * 1024
    /// `PERFORMANCE.md` §2.1: "roughly 1 MB".
    private static let batchByteCap = 1024 * 1024

    public let pty: PTY

    private struct State {
        var terminal: Terminal
    }

    private let state: Mutex<State>
    private let stopped = Mutex(false)

    /// Called from the reader thread whenever a batch has been applied, so
    /// the shell can schedule a redraw. Never called on the main thread by
    /// this type — the shell is responsible for hopping if it needs to.
    public var onOutput: (@Sendable () -> Void)?

    /// Called from the reader thread once the child has exited and the
    /// reader loop has stopped.
    public var onChildExit: (@Sendable (ChildExit) -> Void)?

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

        // A dedicated `Thread`, not a `Task` (`DESIGN.md` §2.2, §2.6): a task
        // can be hopped or starved by unrelated work on the same executor,
        // and draining the PTY must never depend on either.
        ReaderBox(session: self).start()
    }

    deinit {
        stop()
    }

    // MARK: - Reading (runs on `readerThread` only)

    fileprivate func runReaderLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.readChunkSize, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        var batch = [UInt8]()
        batch.reserveCapacity(Self.batchByteCap)

        while !stopped.withLock({ $0 }) {
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
                    read = try pty.read(into: region)
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
            }

            if !batch.isEmpty {
                state.withLock { $0.terminal.feed(batch) }
                onOutput?()
            }

            if reachedEOF { break }
        }

        if let exit = pty.waitForExit() {
            onChildExit?(exit)
        }
    }

    // MARK: - Public API (any thread)

    /// A copy of the current grid. Cheap (`Grid` is a value type); safe to
    /// call from the render thread every frame.
    public func snapshot() -> Grid {
        state.withLock { $0.terminal.grid }
    }

    /// Writes bytes to the child. Never routes attacker-controlled PTY output
    /// back into this call (`SECURITY.md` §6) — it is for keyboard input only.
    public func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            _ = try? pty.writeAll(raw)
        }
    }

    public func resize(to size: TerminalSize) {
        try? pty.resize(to: size)
        state.withLock { current in
            var grid = current.terminal.grid
            grid.resize(rows: Int(size.rows), columns: Int(size.columns))
            current.terminal.grid = grid
        }
    }

    /// Stops the reader thread and hangs up the child. Idempotent.
    public func stop() {
        let wasStopped = stopped.withLock { already -> Bool in
            let was = already
            already = true
            return was
        }
        guard !wasStopped else { return }
        pty.terminate()
        pty.close()
    }
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
        thread.start()
    }
}
