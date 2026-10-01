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

import Darwin
import Dispatch
import Foundation
import Synchronization

/// The SFTP channel: the system `ssh -s -- <host> sftp` over plain pipes, so
/// authentication, host keys and `~/.ssh/config` all belong to OpenSSH.
///
/// The child has **no terminal** (its own session), so ssh cannot prompt: a
/// password, an agent-less passphrase or an unknown host key fails as its own
/// typed error whose remedy is connecting once in the terminal. `SSH_ASKPASS`
/// is honoured by ssh itself.
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
    /// Unknown or changed host key; "yes" can never be typed here.
    case hostKeyUnverified(diagnostics: String)
    case subprocessFailed(exitCode: Int32, diagnostics: String)

    /// Pure, so the policy is testable. Only 255 is ssh's own error (`ssh(1)`);
    /// any other exit or signal is a broken channel.
    public static func classify(exit: ChildExit, diagnostics: String) -> SFTPTransportError {
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

    /// `--` keeps a hostile `host` from becoming an option; user, port, keys and
    /// jump hosts come from `~/.ssh/config`.
    public static func arguments(host: String) -> [String] {
        ["-s", "--", host, subsystemName]
    }

    public let processIdentifier: pid_t
    public let host: String

    private let stdinWrite: GuardedDescriptor
    private let stdoutRead: GuardedDescriptor

    private struct State {
        var exit: ChildExit?
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

    public var exitStatus: ChildExit? { state.withLock { $0.exit } }

    /// Bounded, and for diagnostics only: turns a bare `.connectionLost` into
    /// the classification `classify(exit:)` gives. Never disturbs a live child.
    public func awaitExit(timeout: Duration = .seconds(2)) -> ChildExit? {
        let deadline = ContinuousClock.now + timeout
        var exit: ChildExit?
        while true {
            if exit == nil { exit = reap(blocking: false) }
            // Both the exit and stderr's EOF.
            if exit != nil, stderrDrained.withLock({ $0 }) { return exit }
            if ContinuousClock.now >= deadline { return exit ?? state.withLock { $0.exit } }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Throws only for local failures; remote ones surface as EOF plus
    /// `exitStatus`.
    public static func spawn(
        host: String,
        executable: String = SFTPSubprocessChannel.defaultSSHPath,
        arguments: [String]? = nil,
        environment: [String: String] = ChildEnvironment.default()
    ) throws(SFTPTransportError) -> SFTPSubprocessChannel {
        guard executable.hasPrefix("/") else { throw .executablePathNotAbsolute }

        // No exec-failure pipe (unlike `Spawn.child`, whose trampoline execs a
        // second time): `posix_spawn` reports a failed exec itself, and an
        // inherited pipe would lose close-on-exec — ssh would hold it open and the
        // parent's read would never return.
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
        // `SETSID`: otherwise a Corta launched from a terminal hands ssh that tty,
        // and a prompt hangs in a window nobody is looking at.
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
        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        // The parent's ends stay out of every other child — a shell spawned
        // later must not be able to write frames into this stream, or hold
        // ssh's stdin open past `close()`.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        guard spawnResult == 0 else {
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
        close()
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
        let shouldClose = state.withLock { state -> Bool in
            if state.isClosed { return false }
            state.isClosed = true
            return true
        }
        guard shouldClose else { return }
        // SIGKILL: this is cancellation, and a politely asked child may be stuck
        // in a socket read. Only while unreaped, and decided under the lock
        // `reap` claims: once `waitpid` has run the id is free for the system
        // to give a stranger.
        // A reap in progress means the exit source saw the child go.
        let killed = state.withLock { state -> Bool in
            guard state.exit == nil, !state.isReaping else { return false }
            kill(processIdentifier, SIGKILL)
            return true
        }
        if killed { _ = reap(blocking: true) }
        stdinWrite.close()
        stdoutRead.close()
    }

    /// Only one `waitpid` ever runs for this child, as in `PTY.reap`.
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
        let exit = ChildExit(waitpidStatus: status)
        state.withLock {
            $0.exit = exit
            $0.isReaping = false
        }
        return exit
    }
}

/// A null-terminated `char *[]`, valid for `body`.
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
