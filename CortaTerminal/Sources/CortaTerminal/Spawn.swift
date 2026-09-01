import Darwin

/// Launches a child on a pty replica via `posix_spawn` of the `corta-exec`
/// helper — see `corta-exec/main.swift` for the other half of this.
///
/// This file used to `fork()` the app process directly and run
/// hand-marshalled, async-signal-safe-only code in the forked child before
/// `execve`. That was measured to `SIGKILL` the child roughly 8% of the
/// time under a fully serialized test run (`.serialized` on both PTY test
/// suites, plus a `forkLockStorage` around every `fork()` call — the flake
/// persisted regardless): `fork()` in a heavily multithreaded Cocoa/Swift
/// process is only as safe as whatever lock some *other* thread happens to
/// be holding at the instant of the call, and that hazard cannot be
/// mitigated from inside this process, only avoided by not calling `fork()`
/// at all (`DESIGN.md` §7.2).
///
/// `posix_spawn` cannot express the one thing this needs —
/// `ioctl(TIOCSCTTY)`, required because a session leader does not acquire a
/// controlling terminal merely by having the tty `dup2`'d onto its stdin
/// (`corta-exec/main.swift` has the empirical detail, confirmed by
/// `TerminalSessionTests.controlCStopsAFloodingChild`). `corta-exec` exists
/// to do that one call and then `execve` over itself with the real shell —
/// its own `posix_spawn` already made it a session leader
/// (`POSIX_SPAWN_SETSID`) with the pty replica on fds 0/1/2
/// (`posix_spawn_file_actions_t`), so nothing about this needs `fork()`.
/// Because `corta-exec` is a freshly `execve`'d image, not a forked one,
/// there is no fork-in-a-multithreaded-process hazard here to mitigate —
/// this is pure Swift end to end (`DESIGN.md` §1), not FFI to a hand-rolled
/// C helper.
enum Spawn {
    /// Launches `executable` with the pty replica as its controlling
    /// terminal and standard streams.
    ///
    /// - Parameters:
    ///   - replicaPath: the pty replica's device path, e.g. `/dev/ttys004`.
    ///   - parentReplica: the caller's own open reference to that same
    ///     replica (used only to set the initial window size before this
    ///     call). Closed here, the instant `corta-exec` has its own — see
    ///     the note at the close site.
    ///   - workingDirectory: absolute path, or `nil` to inherit ours.
    static func child(
        executable: String,
        arguments: [String],
        environment: [String: String],
        replicaPath: String,
        parentReplica: Int32,
        workingDirectory: String?
    ) throws(PTYError) -> pid_t {
        // Covers every early-throw path below; the intentional close at the
        // real close site (once `corta-exec` has its own reference) marks
        // this so the deferred one becomes a no-op instead of a double
        // close.
        var parentReplicaClosed = false
        defer { if !parentReplicaClosed { close(parentReplica) } }

        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        guard let helperPath = locateHelperExecutable() else {
            throw .spawnFailed(code: ENOENT)
        }

        // Reports a failed `execve` of `executable` inside `corta-exec` back
        // to us — `posix_spawn`'s return value only covers launching
        // `corta-exec` itself, which always exists and always succeeds.
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else { throw .spawnFailed(code: errno) }
        let readEnd = errorPipe[0]
        let writeEnd = errorPipe[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        // Kept open across `corta-exec`'s own exec by `addinherit_np` below,
        // despite `POSIX_SPAWN_CLOEXEC_DEFAULT`; `FD_CLOEXEC` here is what
        // then closes it automatically the moment `corta-exec` succeeds at
        // `execve`-ing `executable` — the parent's "it worked" signal.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, replicaPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addinherit_np(&fileActions, writeEnd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        // `corta-exec` inherits neither our handlers nor our blocked set
        // (`SECURITY.md` §4.3): every signal reset to its default action,
        // nothing blocked. `execve`-ing `executable` afterwards does not
        // change either, so this covers the real shell too.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        // Only the descriptors above — the pty replica on 0/1/2 and the
        // error pipe's write end — survive into `corta-exec`. Everything
        // else this process happens to have open (sockets, XPC connections,
        // other sessions' ptys) is closed automatically, without needing a
        // hand-written close-everything loop.

        var childArguments = [helperPath, String(writeEnd), workingDirectory ?? "", executable]
        childArguments.append(contentsOf: arguments)
        let environmentLines = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var pid: pid_t = 0
        let spawnResult = withCStringArray(childArguments) { argv in
            withCStringArray(environmentLines) { envp in
                posix_spawn(&pid, helperPath, &fileActions, &attributes, argv, envp)
            }
        }
        guard spawnResult == 0 else {
            close(readEnd)
            close(writeEnd)
            throw .spawnFailed(code: spawnResult)
        }

        // `corta-exec`'s own reference to the replica (opened via
        // `posix_spawn_file_actions_addopen` above) exists the instant
        // `posix_spawn` returns — file actions run as part of spawning,
        // before the call reports success. `parentReplica` can safely go
        // now, and must: waiting any longer (for the pipe read below, which
        // blocks until `corta-exec` finishes `execve`-ing `executable` —
        // arbitrarily long for a child that never exits) risks this being
        // the *last* close of the replica instead of a redundant second
        // one. Empirically, on Darwin, a slave's last close performed by
        // the process that also holds the primary side discards whatever
        // the child had already written and not yet been read. Closing the
        // instant a second reference is guaranteed to exist avoids ever
        // being last, without ever leaving a gap with *no* reference open
        // (a gap here was observed to reset the pty's window size to 0×0).
        close(parentReplica)
        parentReplicaClosed = true

        close(writeEnd)
        defer { close(readEnd) }
        var reportedErrno: Int32 = 0
        let read = withUnsafeMutableBytes(of: &reportedErrno) { buffer -> Int in
            Darwin.read(readEnd, buffer.baseAddress, buffer.count)
        }
        if read > 0 {
            throw .spawnFailed(code: reportedErrno)
        }
        // EOF with nothing written: the write end closed because `corta-exec`
        // exec'd `executable` successfully.
        return pid
    }

    /// `corta-exec`'s path, found next to wherever *this module's own code*
    /// is loaded from.
    ///
    /// SwiftPM builds every product of a package into the same directory
    /// (`corta-dump`, `corta-bench`, the `.xctest` bundle, `corta-exec`
    /// itself). `_NSGetExecutablePath()` would name the wrong binary under
    /// `swift test`: `swift-testing`'s runner (`swiftpm-testing-helper`,
    /// outside the package entirely, in the toolchain) `dlopen`s the
    /// `.xctest` bundle rather than being it, so the *process's* own path
    /// is not where `CortaTerminal` — or `corta-exec` beside it — actually
    /// lives. `dladdr` on an address inside this module reports the image
    /// `dlopen` (or the OS loader) actually mapped it from, which is right
    /// in every case: the bare executable itself for `corta-dump`,
    /// `corta-bench` and a future app, the `.xctest` bundle under
    /// `swift test`.
    private static func locateHelperExecutable() -> String? {
        var info = Dl_info()
        let addressInThisModule = unsafeBitCast(
            addressAnchor, to: UnsafeMutableRawPointer.self)
        guard dladdr(addressInThisModule, &info) != 0, let fname = info.dli_fname else {
            return nil
        }
        var path = String(cString: fname)
        if let resolved = realpath(path, nil) {
            path = String(cString: resolved)
            free(resolved)
        }

        var directory = path
        for _ in 0..<6 {
            guard let slash = directory.lastIndex(of: "/"), slash != directory.startIndex else {
                break
            }
            directory = String(directory[directory.startIndex..<slash])
            let candidate = directory + "/corta-exec"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}

/// An address inside `CortaTerminal`'s own code, for `dladdr` to resolve
/// back to the image this module was loaded from — see
/// `Spawn.locateHelperExecutable`. `@convention(c)`, not a plain Swift
/// closure: a Swift function value can be a fat pointer (code plus a
/// context), and only a C function pointer is guaranteed to be the single
/// pointer `dladdr` needs.
private let addressAnchor: @convention(c) () -> Void = {}

/// Builds a null-terminated `char *[]` from `strings`, valid for the
/// duration of `body`. `posix_spawn` copies everything it needs from `argv`
/// and `envp` before returning, so — unlike the old forked-child path —
/// nothing here needs to outlive this call.
private func withCStringArray<Result>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
