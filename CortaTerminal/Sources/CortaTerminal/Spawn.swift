import Darwin

// Darwin's Swift overlay marks `fork()` `unavailable` ("Please use threads
// or posix_spawn*()") — sound general advice, and exactly why the type
// comment below justifies not taking it here. This binds the real libSystem
// symbol directly, bypassing that annotation; the C function itself is
// unchanged and exactly as async-signal-safe as ever.
@_silgen_name("fork")
private func rawFork() -> pid_t

/// `fork` + a strictly async-signal-safe child body, then `execve`.
///
/// `DESIGN.md` §7.2 prefers `posix_spawn`, but this needs one thing
/// `posix_spawn_file_actions` cannot express: `ioctl(TIOCSCTTY)`.
///
/// A session leader does **not** automatically acquire a controlling
/// terminal by having a tty `dup2`'d onto its stdin, nor — empirically, on
/// Darwin — by *opening* the tty device itself post-`setsid()` the way
/// SVR4/Linux allow. Without an explicit `TIOCSCTTY`, the line discipline
/// has no foreground process group and `^C` never reaches the child
/// (verified by `TerminalSessionTests.controlCStopsAFloodingChild`, which
/// failed against a `posix_spawn`-only implementation that relied on the
/// open-acquires-ctty assumption). `login_tty()` in libutil does exactly
/// this sequence for the same reason; this is that sequence written out by
/// hand rather than linked.
///
/// `DESIGN.md` §7.2's own words: "pre-marshal every argument into C buffers
/// before forking" is the sanctioned alternative to `posix_spawn`, and is
/// taken *literally* here: `childBody` below receives only raw pointers and
/// `Int32`s — never a Swift `Array`, `String`, or closure capturing one.
/// An early version of this file passed `[UnsafeMutablePointer<CChar>?]`
/// (a Swift `Array`, which is a reference-counted, copy-on-write box) as a
/// parameter to the post-`fork` function; that one line intermittently
/// produced impossible-looking failures under a parallel test run —
/// `pty I/O failed: EIO` on a `write` to a *different* test's pty entirely
/// — because passing an `Array` retains it, and a retain touches the
/// allocator's lock. If another thread held that lock at the instant this
/// thread called `fork()`, only this thread survives into the child, and
/// the lock is inherited already held and never released: the classic
/// fork-in-a-multithreaded-process deadlock `DESIGN.md` §7.2 names. Every
/// argument below is a raw `UnsafeMutablePointer`, allocated with `malloc`
/// before `fork()` and walked with pointer arithmetic after it — nothing
/// between `fork()` and `execve()` can touch Swift's allocator.
///
/// **Reporting a failed `exec`.** `fork()` itself almost never fails, so
/// unlike `posix_spawn` (which reports a bad executable path synchronously)
/// a plain `fork`+`execve` would report success even when the child is about
/// to `_exit(127)`. The classic fix — a `CLOEXEC` pipe — is used here: the
/// write end closes itself on a successful `execve` (that is what `CLOEXEC`
/// means) and stays open, with an errno written into it, on any failure
/// before or during `execve`. The parent blocks on a read of that pipe,
/// which resolves the instant one or the other happens.
enum Spawn {
    /// Serializes every `fork()` this process makes.
    ///
    /// `fork()` in a multithreaded process is only as safe as whatever
    /// every *other* thread happens to be doing at that instant — a lock
    /// this file never touches (inside Dispatch, the allocator, the Swift
    /// concurrency runtime) can still be held by some unrelated thread at
    /// the moment of the call, and is inherited held-forever in the child.
    /// Two threads forking at once multiplies that already non-zero risk;
    /// under a test suite spawning many ptys concurrently, that multiplied
    /// risk was observed directly — `swiftpm-testing-helper` occasionally
    /// killed outright by the kernel (`SIGKILL`) partway through a spawn,
    /// confirmed by reverting to `posix_spawn` (no `fork()` at all) and
    /// finding the flake gone. Serializing this process's own `fork()`
    /// calls does not eliminate the underlying hazard — a lock held by a
    /// thread we don't control is still a lock held by a thread we don't
    /// control — but it removes *our* contribution to the odds, and the
    /// real app calls this rarely and at human pace (opening a window, a
    /// split), not the dozens-per-second a parallel test run does.
    ///
    /// A raw `os_unfair_lock`, not `Synchronization.Mutex`: `Mutex.withLock`
    /// is scoped, so *both* the parent and the child would run its unlock
    /// on return from the closure — but `os_unfair_lock` requires unlocking
    /// from the same thread that locked it, and a forked child's thread
    /// identity is not that thread as far as the kernel is concerned. That
    /// combination hung the entire test run outright. Locking and
    /// unlocking are two explicit, separate calls here specifically so the
    /// child branch — which is about to `_exit` anyway — can skip the
    /// unlock rather than be forced through it.
    nonisolated(unsafe) private static var forkLockStorage = os_unfair_lock()

    /// Launches `executable` with the pty replica as its controlling
    /// terminal and standard streams.
    ///
    /// - Parameters:
    ///   - replicaPath: the pty replica's device path, e.g. `/dev/ttys004`.
    ///   - workingDirectory: absolute path, or `nil` to inherit ours.
    static func child(
        executable: String,
        arguments: [String],
        environment: [String: String],
        replicaPath: String,
        workingDirectory: String?
    ) throws(PTYError) -> pid_t {
        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else { throw .spawnFailed(code: errno) }
        let readEnd = errorPipe[0]
        let writeEnd = errorPipe[1]
        // Inherited across `fork`, honoured at `execve`: a successful exec
        // closes this automatically, which is the parent's "it worked"
        // signal.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)

        // Every argument the child needs, as a raw, `malloc`'d C buffer —
        // see the type comment on why this is not a Swift `Array`.
        let executableC = strdup(executable)
        let replicaPathC = strdup(replicaPath)
        let workingDirectoryC = workingDirectory.map { strdup($0) } ?? nil
        let argv = CStringVector([executable] + arguments)
        let envp = CStringVector(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            free(executableC)
            free(replicaPathC)
            if let workingDirectoryC { free(workingDirectoryC) }
            argv.deallocate()
            envp.deallocate()
        }

        os_unfair_lock_lock(&forkLockStorage)
        let pid = rawFork()

        if pid == 0 {
            // Deliberately never unlocks `forkLockStorage` — see its doc
            // comment. This process is about to `_exit`; nothing here will
            // ever contend on it again.
            childBody(
                executable: executableC, replicaPath: replicaPathC,
                workingDirectory: workingDirectoryC, argv: argv.pointer, envp: envp.pointer,
                errorPipeWriteEnd: writeEnd)
            // `childBody` only returns on failure and always reports before
            // returning; `_exit` never runs the Swift runtime's normal
            // teardown, unlike `exit`.
            _exit(127)
        }

        os_unfair_lock_unlock(&forkLockStorage)
        guard pid >= 0 else {
            let code = errno
            close(readEnd)
            close(writeEnd)
            throw .spawnFailed(code: code)
        }

        close(writeEnd)
        defer { close(readEnd) }
        var reportedErrno: Int32 = 0
        let read = withUnsafeMutableBytes(of: &reportedErrno) { buffer -> Int in
            Darwin.read(readEnd, buffer.baseAddress, buffer.count)
        }
        if read > 0 {
            throw .spawnFailed(code: reportedErrno)
        }
        // EOF with nothing written: the write end closed because `execve`
        // succeeded.
        return pid
    }

    /// Everything that runs in the child, between `fork()` and `execve()`.
    /// Async-signal-safe Darwin calls only, on raw pointers — no `String`,
    /// no `Array`, no allocation, no retain (see the type comment).
    private static func childBody(
        executable: UnsafeMutablePointer<CChar>?,
        replicaPath: UnsafeMutablePointer<CChar>?,
        workingDirectory: UnsafeMutablePointer<CChar>?,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        errorPipeWriteEnd: Int32
    ) {
        // A child inherits neither our handlers nor our blocked set
        // (`SECURITY.md` §4.3) — `posix_spawn`'s SETSIGDEF/SETSIGMASK,
        // reproduced by hand.
        for signalNumber in Int32(1)..<NSIG {
            signal(signalNumber, SIG_DFL)
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        sigprocmask(SIG_SETMASK, &emptyMask, nil)

        guard setsid() >= 0 else { reportFailureAndExit(errorPipeWriteEnd) }

        guard let replicaPath else {
            errno = ENOENT
            reportFailureAndExit(errorPipeWriteEnd)
        }
        let fd = open(replicaPath, O_RDWR)
        guard fd >= 0 else { reportFailureAndExit(errorPipeWriteEnd) }

        // The step `posix_spawn_file_actions` cannot express — see the type
        // comment.
        guard ioctl(fd, TIOCSCTTY, 0) == 0 else { reportFailureAndExit(errorPipeWriteEnd) }

        guard dup2(fd, 0) >= 0, dup2(fd, 1) >= 0, dup2(fd, 2) >= 0 else {
            reportFailureAndExit(errorPipeWriteEnd)
        }
        if fd > 2 { close(fd) }

        if let workingDirectory, chdir(workingDirectory) != 0 {
            reportFailureAndExit(errorPipeWriteEnd)
        }

        // `fork()` — unlike `posix_spawn`'s `POSIX_SPAWN_CLOEXEC_DEFAULT` —
        // duplicates every descriptor the host process happens to have open
        // (sockets, XPC connections, other sessions' ptys), not just ours.
        // `FD_CLOEXEC` on our own descriptors (`PTY.openPair`, the error
        // pipe above) covers the ones we control; this closes everything
        // else above stdio as a blanket defence against the ones we don't
        // (`SECURITY.md` process safety) rather than trusting every
        // framework in the host process to have marked its own descriptors
        // close-on-exec. The error pipe's write end is skipped — it still
        // has a job to do if `execve` itself fails below — and closes
        // itself on success via its own `CLOEXEC` flag regardless.
        for candidate in Int32(3)..<1024 where candidate != errorPipeWriteEnd {
            close(candidate)
        }

        guard let executable else {
            errno = ENOENT
            reportFailureAndExit(errorPipeWriteEnd)
        }
        execve(executable, argv, envp)
        // `execve` only returns on failure.
        reportFailureAndExit(errorPipeWriteEnd)
    }

    /// Writes the current `errno` to the parent's error pipe and exits. A
    /// plain top-level function, not a closure — a closure that captures
    /// anything can be heap-allocated under ARC, which is exactly the thing
    /// nothing between `fork()` and `execve()` may do.
    private static func reportFailureAndExit(_ errorPipeWriteEnd: Int32) -> Never {
        var code = errno
        _ = withUnsafeBytes(of: &code) { buffer in
            Darwin.write(errorPipeWriteEnd, buffer.baseAddress, buffer.count)
        }
        _exit(127)
    }
}

/// A null-terminated `char *[]`, as a raw `malloc`'d buffer rather than a
/// Swift `Array` — see the warning in `Spawn`'s documentation on why an
/// `Array` must never cross into the forked child.
private struct CStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
