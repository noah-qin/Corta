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
/// before forking" is the sanctioned alternative to `posix_spawn`, precisely
/// for a case like this. Every string below is `strdup`'d — a C buffer, not
/// a Swift `String` — before `fork()`, and everything between `fork()` and
/// `execve()` is a bare Darwin syscall: no allocation, no retain, nothing
/// that can deadlock a forked single-threaded copy of a multithreaded
/// process.
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

        let executableC = strdup(executable)
        let replicaPathC = strdup(replicaPath)
        let workingDirectoryC = workingDirectory.map { strdup($0) } ?? nil
        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            free(executableC)
            free(replicaPathC)
            if let workingDirectoryC { free(workingDirectoryC) }
            argv.deallocate()
            envp.deallocate()
        }

        let pid = rawFork()
        guard pid >= 0 else {
            let code = errno
            close(readEnd)
            close(writeEnd)
            throw .spawnFailed(code: code)
        }

        if pid == 0 {
            childBody(
                executable: executableC, replicaPath: replicaPathC,
                workingDirectory: workingDirectoryC, argv: argv.pointers, envp: envp.pointers,
                errorPipeWriteEnd: writeEnd)
            // `childBody` only returns on failure and always reports before
            // returning; `_exit` never runs the Swift runtime's normal
            // teardown, unlike `exit`.
            _exit(127)
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
    /// Async-signal-safe Darwin calls only — no `String`, no allocation, no
    /// Swift collections.
    private static func childBody(
        executable: UnsafeMutablePointer<CChar>?,
        replicaPath: UnsafeMutablePointer<CChar>?,
        workingDirectory: UnsafeMutablePointer<CChar>?,
        argv: [UnsafeMutablePointer<CChar>?],
        envp: [UnsafeMutablePointer<CChar>?],
        errorPipeWriteEnd: Int32
    ) {
        func fail() -> Never {
            var code = errno
            _ = withUnsafeBytes(of: &code) { buffer in
                Darwin.write(errorPipeWriteEnd, buffer.baseAddress, buffer.count)
            }
            _exit(127)
        }

        // A child inherits neither our handlers nor our blocked set
        // (`SECURITY.md` §4.3) — `posix_spawn`'s SETSIGDEF/SETSIGMASK,
        // reproduced by hand.
        for signalNumber in Int32(1)..<NSIG {
            signal(signalNumber, SIG_DFL)
        }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        sigprocmask(SIG_SETMASK, &emptyMask, nil)

        guard setsid() >= 0 else { fail() }

        guard let replicaPath else { errno = ENOENT; fail() }
        let fd = open(replicaPath, O_RDWR)
        guard fd >= 0 else { fail() }

        // The step `posix_spawn_file_actions` cannot express — see the type
        // comment.
        guard ioctl(fd, TIOCSCTTY, 0) == 0 else { fail() }

        guard dup2(fd, 0) >= 0, dup2(fd, 1) >= 0, dup2(fd, 2) >= 0 else { fail() }
        if fd > 2 { close(fd) }

        if let workingDirectory, chdir(workingDirectory) != 0 { fail() }

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

        guard let executable else { errno = ENOENT; fail() }
        execve(executable, argv, envp)
        // `execve` only returns on failure.
        fail()
    }
}

/// A null-terminated `char *[]`, owned for the duration of the spawn.
private struct CStringArray {
    var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) }
        pointers.append(nil)
    }

    func deallocate() {
        for pointer in pointers where pointer != nil { free(pointer) }
    }
}
