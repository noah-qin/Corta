import Darwin

/// The other half of `Spawn.swift`'s spawn path.
///
/// `Spawn.child` `posix_spawn`s this binary — a fresh, single-threaded
/// process image, so nothing here runs between a `fork()` and an `execve()`
/// and the async-signal-safety rules that constrained `Spawn.swift`'s old
/// forked-child code do not apply: ordinary Swift, `String`, `Array`,
/// allocation, all fine.
///
/// By the time this file's code runs, `Spawn.child`'s `posix_spawnattr_t`
/// has already made this process a session leader (`POSIX_SPAWN_SETSID`)
/// with the pty replica dup'd onto fds 0/1/2 (`posix_spawn_file_actions_t`).
/// What's left, and what `posix_spawn_file_actions_t` cannot express, is
/// `ioctl(TIOCSCTTY)`: a session leader does not acquire a controlling
/// terminal just by having a tty on fd 0 (see `Spawn.swift`'s doc comment
/// for the empirical detail). Then `execve` over ourselves with the real
/// shell.
///
/// argv: `[self, errorPipeWriteFD, workingDirectory-or-empty, executable,
/// arg0, arg1, ...]`. `executable` doubles as the target's own `argv[0]`,
/// matching what a shell expects to see there.
let arguments = CommandLine.arguments

func fail() -> Never {
    if let pipeFD = Int32(arguments[1]) {
        var code = errno
        withUnsafeBytes(of: &code) { buffer in
            _ = Darwin.write(pipeFD, buffer.baseAddress, buffer.count)
        }
    }
    _exit(127)
}

guard arguments.count >= 4 else { _exit(127) }

// `posix_spawn_file_actions_addinherit_np` (`Spawn.swift`) keeps this
// descriptor open across *our own* exec into this binary, but empirically
// does not carry its `FD_CLOEXEC` flag along — so without re-setting it
// here, it survives into `execve` below too, and a long-lived target (a
// shell waiting on stdin, say) then holds the error pipe's write end open
// indefinitely. The parent's blocking read on the other end never sees
// EOF, and every spawn of anything that doesn't exit immediately hangs.
if let pipeFD = Int32(arguments[1]) {
    _ = fcntl(pipeFD, F_SETFD, FD_CLOEXEC)
}

guard ioctl(0, TIOCSCTTY, 0) == 0 else { fail() }

let workingDirectory = arguments[2]
if !workingDirectory.isEmpty, chdir(workingDirectory) != 0 { fail() }

let targetArguments = Array(arguments[3...])
var targetArgv: [UnsafeMutablePointer<CChar>?] = targetArguments.map { strdup($0) }
targetArgv.append(nil)

execve(targetArguments[0], &targetArgv, environ)
// `execve` only returns on failure.
fail()
