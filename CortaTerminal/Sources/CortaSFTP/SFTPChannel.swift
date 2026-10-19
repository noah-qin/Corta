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

import CortaPOSIX
import Darwin
import Dispatch
import Foundation
import Synchronization

/// The SFTP channel: the system `ssh -s -- <host> sftp` over plain pipes, so
/// authentication, host keys and `~/.ssh/config` all belong to OpenSSH.
///
/// The child has **no terminal** (its own session), so ssh can prompt only
/// through `SSH_ASKPASS`, which the app supplies (D27). Without it — a
/// caller passing none — a password, an agent-less passphrase or an unknown
/// host key fails as its own typed error.
///
/// Pipes, not a PTY — line discipline would corrupt binary frames. Mirrored
/// from `Spawn.child`: absolute paths only, `POSIX_SPAWN_CLOEXEC_DEFAULT`, the
/// signal reset (`SECURITY.md` §4.3); from `PTY`: a closed descriptor is
/// never touched again. Tests inject through `SFTPChannelTransport`.

/// The channel itself breaking — not a server STATUS — and the only kind the
/// transfer engine retries.
public enum SFTPTransportError: Error, Equatable {
    case spawnFailed(code: Int32)
    /// `posix_spawn` does not search `PATH`.
    case executablePathNotAbsolute
    case ioFailed(code: Int32)
    /// The descriptor number may already belong to another file.
    case closed
    case connectionLost
    case authenticationFailed(diagnostics: String)
    case hostUnreachable(diagnostics: String)
    /// Unknown or changed host key, not accepted.
    case hostKeyUnverified(diagnostics: String)
    case subprocessFailed(exitCode: Int32, diagnostics: String)

    /// Pure, so the policy is testable. Only 255 is ssh's own error (`ssh(1)`);
    /// any other exit or signal is a broken channel.
    public static func classify(exit: ProcessExit, diagnostics: String) -> SFTPTransportError {
        guard case .exited(let code) = exit else {
            return .connectionLost
        }
        guard code == 255 else {
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

/// Blocking, like `PTY`; the session reads on a dedicated thread.
public protocol SFTPChannelTransport: AnyObject, Sendable {
    /// 0 at end of file; `.closed` after `close()`.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws(SFTPTransportError) -> Int

    func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError)

    /// Idempotent; afterwards no call touches a descriptor this held.
    func close()
}

public final class SFTPSubprocessChannel: SFTPChannelTransport, @unchecked Sendable {
    public static let defaultSSHPath = "/usr/bin/ssh"

    public static let subsystemName = "sftp"

    /// `--` keeps a hostile `host` from becoming an option. User, port, keys
    /// and jump hosts come from `~/.ssh/config`, unless `options` — which the
    /// caller has validated, since they are passed as they are — name a user
    /// (`-l`), a port (`-p`) or a key (`-i`) of their own.
    ///
    /// What a file channel never needs is switched off, as `sftp(1)` and
    /// `scp(1)` themselves do: a `ForwardAgent yes` meant for interactive
    /// logins would hand the agent to a host a pane's OSC 7 named, and
    /// `LocalForward`/`RemoteForward` would open ports for every browser and
    /// remote-edit connection. A `RemoteCommand` meant for logins makes ssh
    /// refuse the subsystem outright, and `RequestTTY force` would put a
    /// remote terminal's line discipline between the binary frames. And
    /// the channel never becomes a `ControlMaster` itself — a master left
    /// behind would outlive the window — though it still reuses one the
    /// user's terminal opened.
    public static let channelOptions = [
        "-oForwardAgent=no", "-oForwardX11=no", "-oClearAllForwardings=yes",
        "-oPermitLocalCommand=no", "-oRemoteCommand=none", "-oRequestTTY=no",
        "-oControlMaster=no",
    ]

    public static func arguments(host: String, options: [String] = []) -> [String] {
        channelOptions + options + ["-s", "--", host, subsystemName]
    }

    public let processIdentifier: pid_t

    private let stdinWrite: GuardedDescriptor
    private let stdoutRead: GuardedDescriptor

    private struct State {
        var exit: ProcessExit?
        var isReaping = false
        var isClosed = false
    }

    private let state = Mutex(State())
    private let exitQueue: DispatchQueue
    private let exitSource: DispatchSourceProcess

    /// A bounded tail: enough to classify, never growing with a verbose ssh.
    private static let diagnosticsLimit = 64 * 1024
    private let diagnostics = Mutex(Data())
    /// Set at the drain's EOF. The exit is not enough: the pipe can still hold
    /// ssh's last line, and classifying early read `.subprocessFailed` where
    /// `.authenticationFailed` was true.
    private let stderrDrained = Mutex(false)

    public var diagnosticOutput: String {
        let data = diagnostics.withLock { $0 }
        return String(decoding: data, as: UTF8.self)
    }

    /// Bounded, and for diagnostics only: turns a bare `.connectionLost` into
    /// the classification `classify(exit:)` gives. Never disturbs a live child.
    /// Polls by suspending, not sleeping: a lost connection classifies every
    /// in-flight request at once, and a blocked thread each was the
    /// cooperative pool's whole width.
    public func awaitExit(timeout: Duration = .seconds(2)) async -> ProcessExit? {
        let deadline = SuspendingClock.now + timeout
        var exit: ProcessExit?
        while true {
            if exit == nil { exit = reap(blocking: false) }
            // Both the exit and stderr's EOF.
            if exit != nil, stderrDrained.withLock({ $0 }) { return exit }
            // A cancelled task's sleep returns at once: stop rather than spin.
            if SuspendingClock.now >= deadline || Task.isCancelled {
                return exit ?? state.withLock { $0.exit }
            }
            try? await Task.sleep(for: .milliseconds(10), clock: .suspending)
        }
    }

    /// Throws only for local failures; remote ones surface as EOF plus
    /// `exitStatus`. `environment` is the child's whole environment, and has
    /// no default: the app passes the core's sanitised one
    /// (`ChildEnvironment.default()`), which this module cannot see.
    public static func spawn(
        host: String,
        executable: String = SFTPSubprocessChannel.defaultSSHPath,
        arguments: [String]? = nil,
        environment: [String: String],
        beforeStart: (@Sendable (pid_t) -> Void)? = nil
    ) throws(SFTPTransportError) -> SFTPSubprocessChannel {
        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        // No exec-failure pipe (unlike `Spawn.child`, whose trampoline execs a
        // second time): `posix_spawn` reports a failed exec itself, and an
        // inherited pipe would lose close-on-exec — ssh would hold it open and the
        // parent's read would never return.
        let (stdinPipe, stdoutPipe, stderrPipe) = try makeStandardPipes()
        let childArguments = [executable] + (arguments ?? Self.arguments(host: host))
        let spawned = launch(
            executable, arguments: childArguments, environment: environment,
            stdio: (stdinPipe[0], stdoutPipe[1], stderrPipe[1]), suspended: beforeStart != nil)
        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])

        let pid: pid_t
        switch spawned {
        case .success(let spawnedPID):
            pid = spawnedPID
        case .failure(let error):
            Darwin.close(stdinPipe[1])
            Darwin.close(stdoutPipe[0])
            Darwin.close(stderrPipe[0])
            throw .spawnFailed(code: error.code)
        }

        if let beforeStart {
            beforeStart(pid)
            kill(pid, SIGCONT)
        }
        return SFTPSubprocessChannel(
            pid: pid,
            stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0],
            stderrRead: stderrPipe[0])
    }

    /// stdin, stdout and stderr pipes for the child, all or none.
    private static func makeStandardPipes() throws(SFTPTransportError) -> ([Int32], [Int32], [Int32]) {
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
        // The parent's ends get close-on-exec as soon as they exist, not
        // after the spawn: they stay out of every other child spawned
        // meanwhile, which must not write frames into this stream or hold
        // ssh's stdin open past `close()`. (A spawner without
        // `POSIX_SPAWN_CLOEXEC_DEFAULT` in the gap between `pipe` and here
        // still could; macOS has no `pipe2`.) Not the child's ends: one that
        // is already 0, 1 or 2 is `dup2`ed onto itself, which keeps the flag.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        return (stdinPipe, stdoutPipe, stderrPipe)
    }

    /// `posix_spawn`s the child on `stdio`; `suspended` holds it before its
    /// first instruction. The pid, or `posix_spawn`'s error.
    private static func launch(
        _ executable: String, arguments childArguments: [String], environment: [String: String],
        stdio: (input: Int32, output: Int32, error: Int32), suspended: Bool
    ) -> Result<pid_t, SpawnErrorCode> {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdio.input, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdio.output, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stdio.error, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // `SETSID`: otherwise a Corta launched from a terminal hands ssh that tty,
        // and a prompt hangs in a window nobody is looking at.
        // `START_SUSPENDED` when someone must know the pid before the child
        // runs a single instruction (`beforeStart`); resumed just below.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID
                | (suspended ? POSIX_SPAWN_START_SUSPENDED : 0)))
        resetSignals(of: &attributes)

        let environmentLines = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var pid: pid_t = 0
        let spawnResult = withCStringArray(childArguments) { argv in
            withCStringArray(environmentLines) { envp in
                posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
            }
        }
        return spawnResult == 0 ? .success(pid) : .failure(SpawnErrorCode(code: spawnResult))
    }

    /// `posix_spawn`'s error number, as a `Result` failure.
    private struct SpawnErrorCode: Error {
        let code: Int32
    }

    private init(pid: pid_t, stdinWrite: Int32, stdoutRead: Int32, stderrRead: Int32) {
        self.processIdentifier = pid
        self.stdinWrite = GuardedDescriptor(stdinWrite)
        self.stdoutRead = GuardedDescriptor(stdoutRead)
        // EPIPE, never SIGPIPE: its default action kills the whole app.
        _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)
        self.exitQueue = DispatchQueue(label: "dev.corta.sftp.channel.\(pid)")
        self.exitSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: exitQueue)
        exitSource.setEventHandler { [weak self] in
            _ = self?.reap(blocking: true)
        }
        exitSource.resume()

        // Drain forever, or a chatty ssh fills the pipe and stalls the channel.
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
        // Reached unclosed only when nothing called `close`; a closed channel
        // stays alive until its reap has run on `exitQueue`.
        if shutDown() { _ = reap(blocking: true) }
        exitSource.cancel()
    }

    public func read(
        into buffer: UnsafeMutableRawBufferPointer
    ) throws(SFTPTransportError) -> Int {
        guard let base = buffer.baseAddress, !buffer.isEmpty else {
            guard !stdoutRead.isClosed else { throw .closed }
            return 0
        }
        let result = try stdoutRead.withNumber { fd throws(SFTPTransportError) -> Int in
            while true {
                let count = Darwin.read(fd, base, buffer.count)
                if count >= 0 { return count }
                if errno == EINTR { continue }
                // A dead child is EOF here, not EIO — no PTY.
                throw .ioFailed(code: errno)
            }
        }
        guard let result else { throw .closed }
        return result
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws(SFTPTransportError) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            guard !stdinWrite.isClosed else { throw .closed }
            return
        }
        let finished: Void? = try stdinWrite.withNumber { fd throws(SFTPTransportError) in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base + written, bytes.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                // EPIPE is the far end gone: `.closed`, one meaning.
                if count < 0, errno == EPIPE { throw .closed }
                throw .ioFailed(code: errno)
            }
        }
        guard finished != nil else { throw .closed }
    }

    /// Idempotent.
    public func close() {
        // The killed child is reaped on `exitQueue`, not here: `close` runs on
        // the main actor, and a child slow to die must not hold it in
        // `waitpid`. The block retains the channel, so its last release —
        // and `deinit` — come after the reap, off the main thread too.
        guard shutDown() else { return }
        exitQueue.async { _ = self.reap(blocking: true) }
    }

    /// Marks the channel closed, kills the child if it is unreaped and
    /// closes the parent's ends. Whether it killed one, which then needs a
    /// reap; false when already closed or already reaped.
    private func shutDown() -> Bool {
        let shouldClose = state.withLock { state -> Bool in
            if state.isClosed { return false }
            state.isClosed = true
            return true
        }
        guard shouldClose else { return false }
        // SIGKILL: this is cancellation, and a politely asked child may be stuck
        // in a socket read. Only while unreaped, and decided under the lock
        // `reap` claims: once `waitpid` has run the id is free for the system
        // to give a stranger. A reap in progress is waited out rather than
        // trusted — it may be `awaitExit`'s `WNOHANG` probe of a live child —
        // and neither kind blocks: the exit source reaps only an exited child.
        var killed = false
        while true {
            let reaping = state.withLock { state -> Bool in
                if state.exit != nil { return false }
                if state.isReaping { return true }
                kill(processIdentifier, SIGKILL)
                killed = true
                return false
            }
            guard reaping else { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        stdinWrite.close()
        stdoutRead.close()
        return killed
    }

    /// Only one `waitpid` ever runs for this child, as in `PTY.reap`.
    @discardableResult
    private func reap(blocking: Bool) -> ProcessExit? {
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
                status = 0
                break
            }
            if result == 0 {
                state.withLock { $0.isReaping = false }
                return nil
            }
            state.withLock { $0.isReaping = false }
            return state.withLock { $0.exit }
        }
        let exit = ProcessExit(waitpidStatus: status)
        state.withLock {
            $0.exit = exit
            $0.isReaping = false
        }
        return exit
    }
}
