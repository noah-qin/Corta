import Darwin
import Dispatch
import Foundation
import Synchronization

/// B14 — how the SFTP engine moves bytes: a channel to an sftp subsystem
/// over the system ssh.
///
/// The transport is deliberately the *system* ssh (`/usr/bin/ssh`) run as
/// `ssh -s -- <host> sftp`, with plain pipes on stdin/stdout carrying
/// binary SFTP frames and stderr captured for diagnostics. All
/// authentication, host-key, ProxyJump and `~/.ssh/config` behaviour
/// belongs to OpenSSH — with one consequence stated plainly: the child
/// has **no terminal** (it is spawned into its own session, so it cannot
/// inherit one either), so ssh can ask nothing interactively. A password,
/// a key passphrase the agent does not hold, or a host key not yet in
/// `known_hosts` all fail here rather than prompt — as their own typed
/// errors (`authenticationFailed`, `hostKeyUnverified`), each of which
/// says the remedy is a connection in the terminal first. An
/// `SSH_ASKPASS` helper in the environment is honoured by ssh itself, as
/// anywhere else. The rest of the OpenSSH behaviour belongs to ssh itself
/// (B13's division of responsibility): nothing in this file knows what a
/// password or a known-hosts file is. The channel
/// sees three outcomes: bytes flow, the subprocess fails in a way stderr
/// can classify, or the local spawn itself fails.
///
/// `SFTPChannelTransport` is the seam tests inject through: the session
/// and transfer engine only ever see the protocol, and the test suites
/// drive them with an in-memory transport — no real ssh, no network.
///
/// The pipes are *not* a pty. A pty would line-discipline the binary frame
/// stream (CRNL translation, echo) and corrupt it; `Spawn.child`/`PTY`'s
/// TIOCSCTTY machinery exists for interactive shells and is deliberately
/// not reused here. What *is* mirrored from `Spawn.child`: absolute
/// executable paths only, the exec-failure handshake pipe (so a failed
/// `execve` is reported instead of silently pumping an empty channel),
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and the signal reset
/// (`SECURITY.md` §4.3). And from `PTY` (S08): a closed descriptor is
/// never reused — `close()` flips a flag first, and every subsequent read
/// or write fails as `.closed` without touching the recycled number.

/// A failure at the transport layer: the bytes never became an SFTP
/// message. Distinct from a server STATUS, which is the server *answering*
/// — transport failures are the channel itself breaking, and are the only
/// failures the transfer engine will retry.
public enum SFTPTransportError: Error, Equatable {
    /// `posix_spawn` of the ssh executable, or its `execve`, failed.
    case spawnFailed(code: Int32)
    /// The executable path was not absolute (`posix_spawn` does not
    /// search `PATH`, and resolving it here would be a second code path).
    case executablePathNotAbsolute
    /// `read` or `write` on the channel's pipes failed.
    case ioFailed(code: Int32)
    /// The channel was closed; the descriptor number may already belong to
    /// an unrelated file, so it is never used again.
    case closed
    /// The far end closed the channel (EOF on the frame stream) before
    /// the conversation was over.
    case connectionLost
    /// ssh exited 255 with stderr matching an authentication or
    /// permission refusal. Carries the captured diagnostics.
    case authenticationFailed(diagnostics: String)
    /// ssh exited 255 with stderr matching a name-resolution, routing or
    /// connection failure. Carries the captured diagnostics.
    case hostUnreachable(diagnostics: String)
    /// ssh exited 255 because it could not verify the host key without a
    /// terminal to ask on: the host is not in `known_hosts`, or its key
    /// changed. The channel has no tty by design, so "yes" can never be
    /// typed here — the fix is a connection in the terminal first.
    case hostKeyUnverified(diagnostics: String)
    /// ssh exited 255 in a way stderr could not classify further.
    case subprocessFailed(exitCode: Int32, diagnostics: String)

    /// Classifies how the channel ended, from the subprocess's exit status
    /// and what it wrote to stderr. Pure, so the policy is testable
    /// without ever spawning a process.
    ///
    /// ssh's contract (`ssh(1)`: "ssh exits with the exit status of the
    /// remote command or with 255 if an error occurred") is what makes 255
    /// meaningful; any other exit, or a signal, is a broken channel rather
    /// than an ssh-level diagnosis.
    public static func classify(exit: ChildExit, diagnostics: String) -> SFTPTransportError {
        guard case .exited(let code) = exit else {
            return .connectionLost
        }
        guard code == 255 else {
            // The remote sftp-server itself exited non-zero — still a
            // lost channel from the engine's point of view.
            return .connectionLost
        }
        let text = diagnostics.lowercased()
        if text.contains("host key verification failed")
            || text.contains("remote host identification has changed")
        {
            return .hostKeyUnverified(diagnostics: diagnostics)
        }
        if text.contains("permission denied") || text.contains("authentication")
            || text.contains("no supported authentication methods")
        {
            return .authenticationFailed(diagnostics: diagnostics)
        }
        if text.contains("could not resolve hostname")
            || text.contains("name or service not known")
            || text.contains("connection refused") || text.contains("connection timed out")
            || text.contains("operation timed out") || text.contains("no route to host")
            || text.contains("network is unreachable") || text.contains("host is down")
        {
            return .hostUnreachable(diagnostics: diagnostics)
        }
        return .subprocessFailed(exitCode: code, diagnostics: diagnostics)
    }
}

/// The byte-moving half of an SFTP channel. Blocking, matching `PTY`'s
/// read/write shape: the session runs its reader on a dedicated thread,
/// exactly the way `TerminalSession` drains its pty.
public protocol SFTPChannelTransport: AnyObject, Sendable {
    /// Reads up to `buffer.count` bytes. Returns 0 at end of file — the
    /// far end closed the channel. Throws `.closed` after `close()`.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws(SFTPTransportError) -> Int

    /// Writes every byte, looping over short writes.
    /// Throws `.closed` after `close()`.
    func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError)

    /// Ends the channel. Idempotent. For the real transport this kills the
    /// ssh subprocess and reaps it; after `close()` no call may touch a
    /// descriptor number this object held.
    func close()
}

/// The real transport: `/usr/bin/ssh` as a subprocess with plain pipes.
public final class SFTPSubprocessChannel: SFTPChannelTransport, @unchecked Sendable {
    /// The ssh binary. Absolute — inherited from `Spawn`'s rule that this
    /// layer never searches `PATH`.
    public static let defaultSSHPath = "/usr/bin/ssh"

    /// The subsystem name requested with `-s`.
    public static let subsystemName = "sftp"

    /// The argv handed to ssh: `ssh -s -- <host> sftp`.
    ///
    /// `--` stops option parsing so a hostile or malformed `host` cannot
    /// become an option; the subsystem name is the remote command, which
    /// `-s` tells ssh to run as an SSH2 subsystem rather than a shell
    /// command. Everything else — user, port, keys, jump hosts — comes
    /// from `~/.ssh/config`, by design.
    public static func arguments(host: String) -> [String] {
        ["-s", "--", host, subsystemName]
    }

    public let processIdentifier: pid_t
    public let host: String

    private let stdinWrite: Int32
    private let stdoutRead: Int32

    private struct State {
        var exit: ChildExit?
        var isReaping = false
        var isClosed = false
    }

    private let state = Mutex(State())
    private let exitQueue: DispatchQueue
    private let exitSource: DispatchSourceProcess

    /// The child's stderr, drained on a background queue into a bounded
    /// tail buffer — enough to classify a failure, never enough to grow
    /// without bound if ssh is verbose.
    private static let diagnosticsLimit = 64 * 1024
    private let diagnostics = Mutex(Data())
    /// Set once the stderr drain has read EOF — the moment `diagnostics`
    /// is complete. A reaped exit is not that moment: the pipe can still
    /// hold ssh's last line when `waitpid` returns, and a classification
    /// read before the drain caught up saw exit 255 with empty
    /// diagnostics — `.subprocessFailed` where `.authenticationFailed` was
    /// the truth (CI, one run in several).
    private let stderrDrained = Mutex(false)

    /// What the child wrote to stderr so far (bounded tail).
    public var diagnosticOutput: String {
        let data = diagnostics.withLock { $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// How the child ended, or `nil` while it is still running.
    public var exitStatus: ChildExit? { state.withLock { $0.exit } }

    /// Waits — bounded — for the child to exit and be reaped, returning its
    /// exit, or `nil` if it was still running when the wait ran out.
    ///
    /// Diagnostics only, never the frame path: after a failure has already
    /// been delivered, the exit the process source has not quite finished
    /// recording is what turns a bare `.connectionLost` into the
    /// authentication/reachability classification `classify(exit:)` gives.
    /// Polls the non-blocking reap, so a live child is never disturbed.
    public func awaitExit(timeout: Duration = .seconds(2)) -> ChildExit? {
        let deadline = ContinuousClock.now + timeout
        var exit: ChildExit?
        while true {
            if exit == nil { exit = reap(blocking: false) }
            // Both the exit *and* the end of stderr: the diagnostics the
            // classification reads are not complete until the drain has
            // seen EOF, which the child's exit does not guarantee.
            if exit != nil, stderrDrained.withLock({ $0 }) { return exit }
            if ContinuousClock.now >= deadline { return exit ?? state.withLock { $0.exit } }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Spawns the channel. Throws only for local failures; remote-side
    /// failures surface later as EOF on reads plus `exitStatus`.
    public static func spawn(
        host: String,
        executable: String = SFTPSubprocessChannel.defaultSSHPath,
        arguments: [String]? = nil,
        environment: [String: String] = ChildEnvironment.default()
    ) throws(SFTPTransportError) -> SFTPSubprocessChannel {
        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        // stdin: child reads, we write. stdout/stderr: child writes, we
        // read. No exec-failure handshake pipe: `Spawn.child` has one
        // because its child is the `corta-exec` trampoline, which does a
        // *second* `execve` the parent cannot otherwise observe. Here the
        // spawned image *is* the program, and `posix_spawn` on macOS
        // reports a failed exec synchronously in its return value. A pipe
        // handed to the child with `addinherit_np` would have its
        // close-on-exec flag cleared — ssh would hold the write end for
        // its whole life and the parent's read of it would block until
        // ssh exited, which is a connection that never completes (found
        // by the first run against a real `sftp-server`).
        var stdinPipe: [Int32] = [0, 0]
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0
        else {
            let code = errno
            for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1],
                stderrPipe[0], stderrPipe[1]]
            where fd > 0 {
                Darwin.close(fd)
            }
            throw .spawnFailed(code: code)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // No controlling-terminal games (no PTY here — see the file's doc
        // comment), but the same hygiene as `Spawn.child`: nothing this
        // process has open leaks into the child, and the child inherits
        // neither signal handlers nor a blocked set.
        // `SETSID` as well: a Corta launched from a terminal would
        // otherwise hand ssh that terminal as its controlling tty, and ssh
        // would prompt there — a password or host-key question hanging in
        // a window the user is not looking at. With no controlling
        // terminal the prompt fails fast and is classified (`classify`).
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv0 = executable
        let childArguments = [argv0] + (arguments ?? Self.arguments(host: host))
        let environmentLines = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var pid: pid_t = 0
        let spawnResult = withSFTPStringArray(childArguments) { argv in
            withSFTPStringArray(environmentLines) { envp in
                posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
            }
        }
        // The child's ends are dead weight here either way.
        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        guard spawnResult == 0 else {
            // A missing or non-executable `executable` lands here, as the
            // errno `posix_spawn` returns.
            Darwin.close(stdinPipe[1])
            Darwin.close(stdoutPipe[0])
            Darwin.close(stderrPipe[0])
            throw .spawnFailed(code: spawnResult)
        }

        let channel = SFTPSubprocessChannel(
            pid: pid, host: host,
            stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0],
            stderrRead: stderrPipe[0])
        return channel
    }

    private init(pid: pid_t, host: String, stdinWrite: Int32, stdoutRead: Int32, stderrRead: Int32) {
        self.processIdentifier = pid
        self.host = host
        self.stdinWrite = stdinWrite
        self.stdoutRead = stdoutRead
        // A write after the child has closed its stdin must come back as
        // EPIPE (`write` turns it into `.closed`), never as SIGPIPE: nothing
        // in the process ignores that signal, and its default action
        // terminates the whole app — which is what the first upload against
        // a real `sftp-server` did when the server dropped the connection.
        _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)
        self.exitQueue = DispatchQueue(label: "dev.corta.sftp.channel.\(pid)")
        self.exitSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: exitQueue)
        exitSource.setEventHandler { [weak self] in
            _ = self?.reap(blocking: true)
        }
        exitSource.resume()

        // stderr never carries frames, only diagnostics; drain it forever
        // so a chatty ssh (banner warnings, askpass complaints) cannot
        // fill its pipe and stall the channel.
        let stderrSource = DispatchSource.makeReadSource(
            fileDescriptor: stderrRead, queue: exitQueue)
        stderrSource.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(stderrRead, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else {
                self.stderrDrained.withLock { $0 = true }
                stderrSource.cancel()
                return
            }
            self.diagnostics.withLock { data in
                data.append(contentsOf: chunk[0..<count])
                if data.count > Self.diagnosticsLimit {
                    data.removeFirst(data.count - Self.diagnosticsLimit)
                }
            }
        }
        stderrSource.setCancelHandler {
            Darwin.close(stderrRead)
        }
        stderrSource.resume()
    }

    deinit {
        close()
        exitSource.cancel()
    }

    public func read(
        into buffer: UnsafeMutableRawBufferPointer
    ) throws(SFTPTransportError) -> Int {
        guard !state.withLock({ $0.isClosed }) else { throw .closed }
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        while true {
            let count = Darwin.read(stdoutRead, base, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR { continue }
            // The write end of our stdout pipe is the child's stdout; a
            // dead child presents as EOF (count 0), not EIO — no pty here.
            throw .ioFailed(code: errno)
        }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError) {
        guard !state.withLock({ $0.isClosed }) else { throw .closed }
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var written = 0
        while written < bytes.count {
            let count = Darwin.write(stdinWrite, base + written, bytes.count - written)
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            // EPIPE means the child is gone with its stdin read end; that
            // is the channel closing, not an arbitrary I/O error (the
            // descriptor is `F_SETNOSIGPIPE`, so it is EPIPE and not a
            // fatal signal); reporting it as `.closed` keeps one meaning
            // for "the far end is gone".
            if count < 0, errno == EPIPE { throw .closed }
            throw .ioFailed(code: errno)
        }
    }

    /// Kills the child, reaps it, and closes both pipe ends. Safe to call
    /// any number of times; the first call does the work.
    public func close() {
        let shouldClose = state.withLock { state -> Bool in
            if state.isClosed { return false }
            state.isClosed = true
            return true
        }
        guard shouldClose else { return }
        // SIGKILL: closing the channel is cancellation, and a child asked
        // nicely could be stuck in a blocking read on the socket. The
        // process source's handler reaps; `reap(blocking:)` here wins the
        // race to be the single reaper.
        kill(processIdentifier, SIGKILL)
        _ = reap(blocking: true)
        Darwin.close(stdinWrite)
        Darwin.close(stdoutRead)
    }

    /// Single-reaper discipline, mirrored from `PTY.reap`: the process
    /// source and `close()` can both notice the exit, but only one
    /// `waitpid` ever runs for this child.
    @discardableResult
    private func reap(blocking: Bool) -> ChildExit? {
        let shouldReap = state.withLock { state -> Bool in
            if state.exit != nil || state.isReaping { return false }
            state.isReaping = true
            return true
        }
        guard shouldReap else { return state.withLock { $0.exit } }

        var status: Int32 = 0
        let options: Int32 = blocking ? 0 : WNOHANG
        while true {
            let result = waitpid(processIdentifier, &status, options)
            if result == processIdentifier { break }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == ECHILD {
                // Already reaped elsewhere — treat as gone without a status.
                status = 0
                break
            }
            if result == 0 {
                // WNOHANG: still running.
                state.withLock { $0.isReaping = false }
                return nil
            }
            state.withLock { $0.isReaping = false }
            return state.withLock { $0.exit }
        }
        let exit = ChildExit(waitpidStatus: status)
        state.withLock {
            $0.exit = exit
            $0.isReaping = false
        }
        return exit
    }
}

/// Builds a null-terminated `char *[]` from `strings`, valid for the
/// duration of `body`. A local copy of `Spawn.swift`'s helper — that one
/// is private to its file, and this one needs nothing more from it.
private func withSFTPStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
