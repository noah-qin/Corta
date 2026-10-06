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
import Synchronization

/// A pseudoterminal and the process running on it. Off the main thread
/// (D04) and owned by a session, never a singleton (D07).
public final class PTY: @unchecked Sendable {
    /// Owned by this object; do not close it. A bare number: after `close()`
    /// it may name another file, so a caller that polls it directly must
    /// stop once the session has.
    public var fileDescriptor: Int32 { descriptor.number }

    /// Every system call on the primary goes through this, so a `close()` on
    /// another thread can never hand an in-flight call a recycled number.
    private let descriptor: GuardedDescriptor

    /// Also the group and session id (`POSIX_SPAWN_SETSID`).
    public let processIdentifier: pid_t

    public let replicaPath: String

    private struct State {
        var exit: ChildExit?
        /// Two reapers never race for one status.
        var isReaping = false
    }

    private let state = Mutex(State())
    private let exited = DispatchGroup()
    private let exitQueue: DispatchQueue
    private let exitSource: DispatchSourceProcess
    private let terminationHandler: (@Sendable (ChildExit) -> Void)?

    // MARK: - Spawning

    /// - Parameters:
    ///   - executable: absolute; `PATH` is not searched.
    ///   - environment: sanitised by default (`ChildEnvironment`).
    ///   - size: applied before the child starts, so it never sees 0×0.
    ///   - terminationHandler: once, off the main thread, when reaped.
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
        // `Spawn.child` closes `replica` the instant `corta-exec` holds its own —
        // see the close site for why the timing matters.
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
        self.descriptor = GuardedDescriptor(fileDescriptor)
        self.processIdentifier = processIdentifier
        self.replicaPath = replicaPath
        self.terminationHandler = terminationHandler
        // `.userInitiated`, matching `waitForExit`'s callers: a `DispatchGroup`
        // does not propagate its waiter's QoS, so a default queue would be a
        // priority inversion.
        self.exitQueue = DispatchQueue(
            label: "com.corta.pty.child.\(processIdentifier)", qos: .userInitiated)
        // `NOTE_EXIT`, not a `SIGCHLD` handler: signal dispositions are
        // process-wide.
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
        descriptor.close()
        if state.withLock({ $0.exit == nil }) { exited.leave() }
    }

    private static func openPair() throws(PTYError) -> (
        primary: Int32, replica: Int32, path: String
    ) {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0 else { throw .openFailed(code: errno) }
        // So no other child this process starts (a `Process`, another session)
        // inherits the primary side.
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

        // We must not acquire this terminal; the child does, as session leader.
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

    /// 0 at end of file — including Darwin's `EIO` once the replica closes.
    /// `.closed` after `close()`: the number may already be another file's.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws(PTYError) -> Int {
        guard let base = buffer.baseAddress, !buffer.isEmpty else {
            guard !descriptor.isClosed else { throw .closed }
            return 0
        }
        let result = try descriptor.withNumber { fd throws(PTYError) -> Int in
            while true {
                let count = Darwin.read(fd, base, buffer.count)
                if count >= 0 { return count }
                switch errno {
                case EINTR: continue
                case EIO: return 0
                case let code: throw .ioFailed(code: code)
                }
            }
        }
        guard let result else { throw .closed }
        return result
    }

    /// Whether a read would return without blocking, waiting up to
    /// `timeoutMilliseconds` (`-1`: no limit). End of file and errors count as
    /// readable — the read reports them. `.closed` after `close()`.
    public func waitUntilReadable(timeoutMilliseconds: Int32) throws(PTYError) -> Bool {
        let result = descriptor.withNumber { fd -> Bool in
            while true {
                var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&request, 1, timeoutMilliseconds)
                if ready >= 0 { return request.revents != 0 }
                if errno != EINTR { return true }
            }
        }
        guard let result else { throw .closed }
        return result
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws(PTYError) -> Int {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            guard !descriptor.isClosed else { throw .closed }
            return 0
        }
        let result = try descriptor.withNumber { fd throws(PTYError) -> Int in
            while true {
                let count = Darwin.write(fd, base, bytes.count)
                if count >= 0 { return count }
                if errno == EINTR { continue }
                throw .ioFailed(code: errno)
            }
        }
        guard let result else { throw .closed }
        return result
    }

    @discardableResult
    public func writeAll(_ bytes: UnsafeRawBufferPointer) throws(PTYError) -> Int {
        var written = 0
        while written < bytes.count {
            written += try write(UnsafeRawBufferPointer(rebasing: bytes[written...]))
        }
        return written
    }

    // MARK: - Window size

    /// The kernel raises `SIGWINCH` on the foreground group.
    public func resize(to size: TerminalSize) throws(PTYError) {
        var windowSize = size.winsize
        let code = descriptor.withNumber { fd -> Int32 in
            ioctl(fd, TIOCSWINSZ, &windowSize) == 0 ? 0 : errno
        }
        guard let code else { throw .closed }
        guard code == 0 else { throw .resizeFailed(code: code) }
    }

    public func size() throws(PTYError) -> TerminalSize {
        var windowSize = Darwin.winsize()
        let code = descriptor.withNumber { fd -> Int32 in
            ioctl(fd, TIOCGWINSZ, &windowSize) == 0 ? 0 : errno
        }
        guard let code else { throw .closed }
        guard code == 0 else { throw .resizeFailed(code: code) }
        return TerminalSize(windowSize)
    }

    // MARK: - Child lifecycle

    public var exitStatus: ChildExit? { state.withLock { $0.exit } }

    /// "Is anything running?" without shell integration: a job gets its own
    /// group and the terminal, so a foreground group that is not the shell is a
    /// command. `nil` once the child exited or the descriptor closed.
    public var foregroundProcessGroup: pid_t? {
        let group = descriptor.withNumber { tcgetpgrp($0) } ?? -1
        return group > 0 ? group : nil
    }

    public var hasForegroundJob: Bool {
        guard let group = foregroundProcessGroup else { return false }
        return group != processIdentifier
    }

    /// `nil` for the shell itself, or when unreadable.
    public var foregroundProcessName: String? {
        guard let group = foregroundProcessGroup, group != processIdentifier else { return nil }
        return Self.processName(ofGroup: group)
    }

    /// Unlike `foregroundProcessName`, includes the shell: a title bar says
    /// "zsh"; a close confirmation must not.
    public var activeProcessName: String? {
        guard let group = foregroundProcessGroup else { return nil }
        return Self.processName(ofGroup: group)
    }

    /// The group leader's name, else a live member's: in `seq 1 500 | less`
    /// the leader is `seq`, gone at once while `less` holds the terminal, and
    /// a nameless foreground job read as "remote?" in the title.
    private static func processName(ofGroup group: pid_t) -> String? {
        if let name = processName(of: group) { return name }
        var members = [pid_t](repeating: 0, count: 64)
        let count = proc_listpgrppids(
            group, &members, Int32(members.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        // The last listed is the newest — the pipeline's reader, usually.
        for member in members.prefix(Int(min(count, Int32(members.count)))).reversed() {
            if let name = processName(of: member) { return name }
        }
        return nil
    }

    /// Trusts the length `proc_name` returns; `String(cString:)` on `[CChar]`
    /// is deprecated.
    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// From the kernel (`proc_pidinfo`): stock macOS zsh emits OSC 7 only for
    /// Terminal.app, and this cannot be spoofed by output. Not cached — the
    /// caller decides how often the syscall is worth it.
    public var currentWorkingDirectory: String? {
        guard let group = foregroundProcessGroup else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(group, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// To the group — the shell's children are what the user wants stopped
    /// (`SECURITY.md` §4.4). Refused once reaped: the id may be recycled.
    @discardableResult
    public func signalProcessGroup(_ signal: Int32) -> Bool {
        guard state.withLock({ $0.exit == nil }) else { return false }
        return kill(-processIdentifier, signal) == 0
    }

    @discardableResult
    public func terminate() -> Bool {
        signalProcessGroup(SIGHUP)
    }

    /// `nil` on timeout. For tests and teardown.
    @discardableResult
    public func waitForExit(timeout: Duration = .seconds(10)) -> ChildExit? {
        if exited.wait(timeout: .now() + timeout.dispatchInterval) == .success {
            return exitStatus
        }
        return reap(blocking: false)
    }

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

    /// Idempotent, and never waits. The child sees EOF; `terminate()` first to
    /// also hang up. A call still in flight on another thread keeps the
    /// descriptor until it returns — so it can never reach a recycled number —
    /// and the last one out closes it.
    public func close() {
        descriptor.close()
    }
}
