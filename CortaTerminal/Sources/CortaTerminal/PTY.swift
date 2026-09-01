import Darwin
import Dispatch
import Synchronization

/// A pseudoterminal and the process running on it.
///
/// Nonisolated by construction: the reader that drains this lives off the
/// main thread (`DESIGN.md` §2.2). Nothing here touches AppKit, and nothing
/// here is a singleton — a `PTY` is owned by a session, and a window may hold
/// many (`DESIGN.md` §2.4).
public final class PTY: @unchecked Sendable {
    /// The primary side of the pty. Read the child's output from it, write
    /// the user's input to it. Owned by this object; do not close it.
    public let fileDescriptor: Int32

    /// The child's process id. It is also its process group and session id,
    /// because it was spawned with `POSIX_SPAWN_SETSID`.
    public let processIdentifier: pid_t

    /// The path of the replica, e.g. `/dev/ttys004`. Useful in diagnostics.
    public let replicaPath: String

    private struct State {
        var exit: ChildExit?
        /// Set while a thread is inside `waitpid` for this child, so that two
        /// reapers never race for the same status.
        var isReaping = false
        var isClosed = false
    }

    private let state = Mutex(State())
    private let exited = DispatchGroup()
    private let exitQueue: DispatchQueue
    private let exitSource: DispatchSourceProcess
    private let terminationHandler: (@Sendable (ChildExit) -> Void)?

    // MARK: - Spawning

    /// Opens a pty and starts `executable` on it.
    ///
    /// - Parameters:
    ///   - executable: an absolute path. `PATH` is deliberately not searched.
    ///   - arguments: argv[1...]; argv[0] is `executable`.
    ///   - environment: defaults to this process's environment, sanitised
    ///     (`ChildEnvironment`).
    ///   - size: the initial window size, applied before the child starts so
    ///     that it never observes a 0×0 terminal.
    ///   - terminationHandler: called once, off the main thread, when the
    ///     child is reaped.
    public static func spawn(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ChildEnvironment.default(),
        size: TerminalSize = TerminalSize(),
        workingDirectory: String? = nil,
        terminationHandler: (@Sendable (ChildExit) -> Void)? = nil
    ) throws(PTYError) -> PTY {
        let (primary, replica, path) = try openPair()

        var windowSize = size.winsize
        guard ioctl(replica, TIOCSWINSZ, &windowSize) == 0 else {
            let code = errno
            Darwin.close(replica)
            Darwin.close(primary)
            throw .resizeFailed(code: code)
        }
        // `replica` itself (as opposed to the window size just set through
        // it, which lives on the pty, not the fd) is handed to `Spawn.child`
        // to close once — and exactly once — `corta-exec` is guaranteed to
        // have its own reference; see the close site there for why the
        // timing matters.
        let pid: pid_t
        do {
            pid = try Spawn.child(
                executable: executable,
                arguments: arguments,
                environment: environment,
                replicaPath: path,
                parentReplica: replica,
                workingDirectory: workingDirectory
            )
        } catch {
            Darwin.close(primary)
            throw error
        }

        return PTY(
            fileDescriptor: primary,
            processIdentifier: pid,
            replicaPath: path,
            terminationHandler: terminationHandler
        )
    }

    private init(
        fileDescriptor: Int32,
        processIdentifier: pid_t,
        replicaPath: String,
        terminationHandler: (@Sendable (ChildExit) -> Void)?
    ) {
        self.fileDescriptor = fileDescriptor
        self.processIdentifier = processIdentifier
        self.replicaPath = replicaPath
        self.terminationHandler = terminationHandler
        self.exitQueue = DispatchQueue(label: "com.corta.pty.child.\(processIdentifier)")
        // Child exit arrives through kqueue's `NOTE_EXIT` rather than a
        // `SIGCHLD` handler: signal dispositions are process-wide, and a
        // library that installs one fights whatever else the app does with
        // children. This delivers the same event, per child, with no global
        // state.
        self.exitSource = DispatchSource.makeProcessSource(
            identifier: processIdentifier, eventMask: .exit, queue: exitQueue
        )
        exited.enter()
        exitSource.setEventHandler { [weak self] in
            _ = self?.reap(blocking: true)
        }
        exitSource.resume()
    }

    deinit {
        exitSource.cancel()
        if !state.withLock({ $0.isClosed }) { Darwin.close(fileDescriptor) }
        // Balance `enter()` so the group is never left dangling.
        if state.withLock({ $0.exit == nil }) { exited.leave() }
    }

    /// `posix_openpt` + `grantpt` + `unlockpt` + `open`.
    private static func openPair() throws(PTYError) -> (
        primary: Int32, replica: Int32, path: String
    ) {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0 else { throw .openFailed(code: errno) }
        // `Spawn.child` uses `fork()`, which (unlike `posix_spawn`'s
        // `POSIX_SPAWN_CLOEXEC_DEFAULT`) duplicates every open descriptor
        // into the child, including this one — `FD_CLOEXEC` is what makes
        // `execve` close it again before the child's own code ever runs.
        _ = fcntl(primary, F_SETFD, FD_CLOEXEC)

        guard grantpt(primary) == 0, unlockpt(primary) == 0 else {
            let code = errno
            Darwin.close(primary)
            throw .openFailed(code: code)
        }

        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        let named = ptsname_r(primary, &name, name.count)
        guard named == 0 else {
            let code = errno
            Darwin.close(primary)
            throw .openFailed(code: code)
        }
        let path = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        // O_NOCTTY here: *we* must not acquire this terminal. The child does,
        // by being a session leader with it on fd 0.
        let replica = open(path, O_RDWR | O_NOCTTY)
        guard replica >= 0 else {
            let code = errno
            Darwin.close(primary)
            throw .openFailed(code: code)
        }
        _ = fcntl(replica, F_SETFD, FD_CLOEXEC)
        return (primary, replica, path)
    }

    // MARK: - I/O

    /// Reads available output. Returns 0 at end of file.
    ///
    /// On Darwin a primary descriptor whose replica has closed reports `EIO`
    /// rather than a zero-length read; that is end of file, not a failure.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws(PTYError) -> Int {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        while true {
            let count = Darwin.read(fileDescriptor, base, buffer.count)
            if count >= 0 { return count }
            switch errno {
            case EINTR: continue
            case EIO: return 0
            case let code: throw .ioFailed(code: code)
            }
        }
    }

    /// Writes as much as the pty accepts, and returns how much that was.
    public func write(_ bytes: UnsafeRawBufferPointer) throws(PTYError) -> Int {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return 0 }
        while true {
            let count = Darwin.write(fileDescriptor, base, bytes.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw .ioFailed(code: errno)
        }
    }

    /// Writes every byte, looping over short writes.
    @discardableResult
    public func writeAll(_ bytes: UnsafeRawBufferPointer) throws(PTYError) -> Int {
        var written = 0
        while written < bytes.count {
            written += try write(UnsafeRawBufferPointer(rebasing: bytes[written...]))
        }
        return written
    }

    // MARK: - Window size

    /// Sets the window size and lets the kernel raise `SIGWINCH` on the
    /// child's foreground process group.
    public func resize(to size: TerminalSize) throws(PTYError) {
        var windowSize = size.winsize
        guard ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw .resizeFailed(code: errno)
        }
    }

    /// The size the child currently sees.
    public func size() throws(PTYError) -> TerminalSize {
        var windowSize = Darwin.winsize()
        guard ioctl(fileDescriptor, TIOCGWINSZ, &windowSize) == 0 else {
            throw .resizeFailed(code: errno)
        }
        return TerminalSize(windowSize)
    }

    // MARK: - Child lifecycle

    /// How the child ended, or `nil` while it is still running.
    public var exitStatus: ChildExit? { state.withLock { $0.exit } }

    /// Sends a signal to the child's process *group*.
    ///
    /// The group, not the process: the child is a shell, and its own children
    /// are what the user actually cares about stopping (`SECURITY.md` §4.4).
    @discardableResult
    public func signalProcessGroup(_ signal: Int32) -> Bool {
        kill(-processIdentifier, signal) == 0
    }

    /// Hangs up the child's process group, the way closing a window should.
    @discardableResult
    public func terminate() -> Bool {
        signalProcessGroup(SIGHUP)
    }

    /// Blocks until the child exits, or `timeout` elapses.
    ///
    /// Returns `nil` on timeout. Intended for tests and teardown; the app
    /// uses `terminationHandler`.
    @discardableResult
    public func waitForExit(timeout: Duration = .seconds(10)) -> ChildExit? {
        let nanoseconds = timeout.components.seconds * 1_000_000_000
            + timeout.components.attoseconds / 1_000_000_000
        if exited.wait(timeout: .now() + .nanoseconds(Int(nanoseconds))) == .success {
            return exitStatus
        }
        // The exit source may not have fired yet if the child died before it
        // was armed. Ask directly rather than hang.
        return reap(blocking: false)
    }

    /// Reaps the child exactly once and publishes the result.
    @discardableResult
    private func reap(blocking: Bool) -> ChildExit? {
        let claimed = state.withLock { state -> Bool in
            guard state.exit == nil, !state.isReaping else { return false }
            state.isReaping = true
            return true
        }
        guard claimed else { return exitStatus }

        var status: Int32 = 0
        let options = blocking ? 0 : WNOHANG
        var reaped: pid_t
        repeat {
            reaped = waitpid(processIdentifier, &status, options)
        } while reaped < 0 && errno == EINTR
        guard reaped == processIdentifier else {
            state.withLock { $0.isReaping = false }
            return nil
        }

        let exit = ChildExit(waitpidStatus: status)
        state.withLock {
            $0.exit = exit
            $0.isReaping = false
        }
        exited.leave()
        exitSource.cancel()
        terminationHandler?(exit)
        return exit
    }

    /// Closes the primary descriptor. Idempotent.
    ///
    /// The child then sees end of file on its terminal; call `terminate()`
    /// first if it should also be told to go away.
    public func close() {
        let shouldClose = state.withLock { state -> Bool in
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        guard shouldClose else { return }
        Darwin.close(fileDescriptor)
    }
}
