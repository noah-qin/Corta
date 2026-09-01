import Darwin

/// `posix_spawn`, wrapped.
///
/// `fork` is not an option. Between `fork` and `exec` only async-signal-safe
/// functions are legal, and the Swift runtime is not: allocating, retaining
/// or touching a `String` in the child can deadlock intermittently — the
/// worst possible failure mode (`DESIGN.md` §7.2). Every argument is
/// marshalled into C buffers *before* the call, and the kernel performs the
/// session, descriptor and signal work on our behalf.
enum Spawn {
    /// Launches `executable` with the pty replica as its standard streams.
    ///
    /// - Parameters:
    ///   - replica: the pty replica; becomes the child's fd 0, 1 and 2, and
    ///     its controlling terminal.
    ///   - workingDirectory: absolute path, or `nil` to inherit ours.
    static func child(
        executable: String,
        arguments: [String],
        environment: [String: String],
        replica: Int32,
        workingDirectory: String?
    ) throws(PTYError) -> pid_t {
        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        var fileActions: posix_spawn_file_actions_t?
        let fileActionsCode = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsCode == 0 else {
            throw .spawnFailed(code: fileActionsCode)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory {
            let code = posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)
            guard code == 0 else { throw .spawnFailed(code: code) }
        }

        // The replica becomes stdin, stdout and stderr. Because the child is
        // made a session leader (below), dup'ing a tty onto its stdin also
        // makes that tty its controlling terminal, which is what gives it job
        // control and signal delivery.
        for target in Int32(0)...Int32(2) {
            let code = posix_spawn_file_actions_adddup2(&fileActions, replica, target)
            guard code == 0 else { throw .spawnFailed(code: code) }
        }
        if replica > 2 {
            let code = posix_spawn_file_actions_addclose(&fileActions, replica)
            guard code == 0 else { throw .spawnFailed(code: code) }
        }

        var attributes: posix_spawnattr_t?
        let attributesCode = posix_spawnattr_init(&attributes)
        guard attributesCode == 0 else {
            throw .spawnFailed(code: attributesCode)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // POSIX_SPAWN_SETSID       — new session; the child leads it.
        // POSIX_SPAWN_CLOEXEC_DEFAULT — close every descriptor the file
        //                            actions do not name. The primary side of
        //                            the pty must never reach the child.
        // SETSIGDEF / SETSIGMASK   — a child inherits neither our handlers
        //                            nor our blocked set (`SECURITY.md` §4.3).
        let flags = POSIX_SPAWN_SETSID
            | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        let flagsCode = posix_spawnattr_setflags(&attributes, Int16(flags))
        guard flagsCode == 0 else {
            throw .spawnFailed(code: flagsCode)
        }

        var defaulted = sigset_t()
        sigfillset(&defaulted)
        let defaultsCode = posix_spawnattr_setsigdefault(&attributes, &defaulted)
        guard defaultsCode == 0 else {
            throw .spawnFailed(code: defaultsCode)
        }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        let maskCode = posix_spawnattr_setsigmask(&attributes, &unblocked)
        guard maskCode == 0 else {
            throw .spawnFailed(code: maskCode)
        }

        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            argv.deallocate()
            envp.deallocate()
        }

        var pid: pid_t = 0
        let code = posix_spawn(
            &pid, executable, &fileActions, &attributes, argv.pointers, envp.pointers
        )
        guard code == 0 else { throw .spawnFailed(code: code) }
        return pid
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
