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
import Foundation
import Synchronization

// MARK: - The app's end

/// Listens for askpass requests and answers each through `prompter`.
///
/// A request is answered only when all of these hold (`SECURITY.md` §4.8):
/// it arrives on a socket in a `0700` directory of the user's own
/// temporary folder; it carries the token of a live grant, compared in
/// constant time; and the process sending it descends from an ssh that
/// grant's connection spawned — the same process, not a later one given
/// its recycled pid (`ProcessRecord.started`). The token alone is in ssh's
/// environment, which the same user's processes can read; the ancestry
/// check is what ties a request to that ssh.
nonisolated final class SSHAskpassBroker: @unchecked Sendable {
    /// Asks the user; nil is a refusal. Cancelled when the asking process
    /// goes away — ssh gave up, or the connection was closed.
    typealias Prompter = @Sendable (_ asking: SSHAskpass.Asking) async -> String?

    /// A process's parent, and when it started: a pid is reused once its
    /// process is gone, its start time is not.
    struct ProcessRecord: Equatable, Sendable {
        var parent: pid_t
        var started: UInt64
    }

    static let shared = SSHAskpassBroker(
        executable: Bundle.main.executablePath,
        prompter: { asking in await SSHAskpassPrompter.ask(asking) })

    /// How far above the asker its connection's ssh may be: ssh itself (1),
    /// or the inner ssh of a `ProxyJump` asking for the jump host (2), with
    /// room for a `ProxyCommand` wrapper or two.
    static let ancestryLimit = 4

    /// Clients that have connected and not yet sent their one line. Each
    /// holds a thread in a blocking read, so they are bounded; a dialog holds
    /// no thread. Past it a client is dropped, which ssh reads as cancelled.
    static let readingClientLimit = 16

    /// A connection's permission to ask: the host its dialogs name, the
    /// environment (with its token) its ssh runs under, and the ssh
    /// processes it spawned. Held by the connection; the
    /// broker keeps it weakly, so a closed connection can ask nothing.
    final class Grant: Sendable {
        let host: String
        let environment: [String: String]
        private let processes = Mutex([pid_t: UInt64]())
        private let record: @Sendable (pid_t) -> ProcessRecord?

        fileprivate init(
            host: String, environment: [String: String],
            record: @escaping @Sendable (pid_t) -> ProcessRecord?
        ) {
            self.host = host
            self.environment = environment
            self.record = record
        }

        /// An ssh this connection spawned, recorded while it is still
        /// suspended (`SFTPSubprocessChannel.spawn`'s `beforeStart`).
        func admit(_ pid: pid_t) {
            guard let started = record(pid)?.started else { return }
            // Every reconnect spawns another ssh; the ones that have exited
            // since are let go here, in the same pass, so a long-lived
            // connection's list stays as long as its live processes.
            processes.withLock { processes in
                processes = processes.filter { record($0.key)?.started == $0.value }
                processes[pid] = started
            }
        }

        /// That very process: alive, and started when it was admitted.
        func admits(_ pid: pid_t) -> Bool {
            guard let admitted = processes.withLock({ $0[pid] }) else { return false }
            return record(pid)?.started == admitted
        }
    }

    private struct WeakGrant {
        weak var grant: Grant?
    }

    private struct State {
        var source: DispatchSourceRead?
        var directory: String?
        var socketPath: String?
        var grants: [String: WeakGrant] = [:]
        /// Set on a failed setup, and by `stop()`: nothing listens again.
        var closed = false
    }

    private let executable: String?
    private let prompter: Prompter
    private let record: @Sendable (pid_t) -> ProcessRecord?
    private let terminate: @Sendable (pid_t) -> Void
    private let ownProcess: pid_t
    private let acceptQueue = DispatchQueue(label: "dev.noahqin.Corta.askpass")
    private let state = Mutex(State())
    private let requestTimeout: Duration
    private let readingClients: PathProbe.Budget
    /// How often an open dialog looks whether its ssh is still there.
    private let askerCheckInterval: Duration

    init(
        executable: String?, prompter: @escaping Prompter,
        record: @escaping @Sendable (pid_t) -> ProcessRecord? = SSHAskpassBroker.processRecord(of:),
        terminate: @escaping @Sendable (pid_t) -> Void = SSHAskpassBroker.terminateConnection(_:),
        requestTimeout: Duration = .seconds(5),
        readingClientLimit: Int = SSHAskpassBroker.readingClientLimit,
        askerCheckInterval: Duration = .milliseconds(500)
    ) {
        self.executable = executable
        self.prompter = prompter
        self.record = record
        self.terminate = terminate
        self.requestTimeout = requestTimeout
        self.readingClients = PathProbe.Budget(limit: readingClientLimit)
        self.askerCheckInterval = askerCheckInterval
        self.ownProcess = getpid()
    }

    deinit {
        stop()
    }

    /// Ends a connection's ssh. Never Corta itself.
    static func terminateConnection(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        kill(pid, SIGTERM)
    }

    /// A grant for one connection to `host`, listening first if this is the
    /// first. Nil when the socket cannot be set up, or after `stop()` — the
    /// connection then runs without askpass, and a question fails to sign in.
    func grant(host: String) -> Grant? {
        guard let executable, let socketPath = listen(), let token = SSHAskpass.makeToken() else {
            return nil
        }
        let grant = Grant(
            host: host,
            environment: SSHAskpass.environment(
                executable: executable, socketPath: socketPath, token: token),
            record: record)
        state.withLock { state in
            state.grants = state.grants.filter { $0.value.grant != nil }
            state.grants[token] = WeakGrant(grant: grant)
        }
        return grant
    }

    /// Closes the socket and removes its directory, for good.
    func stop() {
        let (source, directory, path) = state.withLock { state in
            defer {
                state.source = nil
                state.directory = nil
                state.socketPath = nil
                state.closed = true
            }
            return (state.source, state.directory, state.socketPath)
        }
        source?.cancel()
        if let path { unlink(path) }
        if let directory { rmdir(directory) }
    }

    nonisolated static func pruneAbandoned() {
        let directory = NSTemporaryDirectory()
        let manager = FileManager.default
        let prefix = "corta-askpass."
        for name in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix(prefix) {
            let parts = name.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
            guard parts.count == 2, parts[1].count == 6,
                let pid = Int32(parts[0]), pid > 0, kill(pid, 0) == -1, errno == ESRCH
            else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR
            else { continue }
            unlink((path as NSString).appendingPathComponent("s"))
            rmdir(path)
        }
    }

}

// MARK: - Listening

nonisolated extension SSHAskpassBroker {
    private func listen() -> String? {
        state.withLock { state -> String? in
            if let path = state.socketPath { return path }
            guard !state.closed else { return nil }
            // A fresh 0700 directory in the per-user temporary folder: no
            // other user can reach the socket, and nothing stale is reused.
            let template = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("corta-askpass.\(getpid()).XXXXXX")
            var buffer = Array(template.utf8CString)
            guard let made = mkdtemp(&buffer) else { state.closed = true; return nil }
            let directory = String(cString: made)
            let path = (directory as NSString).appendingPathComponent("s")
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard var address = SSHAskpass.socketAddress(path), listener >= 0 else {
                if listener >= 0 { close(listener) }
                rmdir(directory)
                state.closed = true
                return nil
            }
            _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(listener, 8) == 0 else {
                close(listener)
                unlink(path)
                rmdir(directory)
                state.closed = true
                return nil
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
            source.setEventHandler { [weak self] in self?.acceptOne(on: listener) }
            source.setCancelHandler { close(listener) }
            source.resume()
            state.source = source
            state.directory = directory
            state.socketPath = path
            return path
        }
    }

    /// Accepts only; each client is read, checked and answered on a queue
    /// of its own, so one that is slow or silent holds up no other.
    private func acceptOne(on listener: Int32) {
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        guard readingClients.take() else {
            close(descriptor)
            return
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let client = Client(descriptor: descriptor)
        let readingClients = readingClients
        client.queue.async { [weak self] in
            guard let self else {
                client.close()
                readingClients.give()
                return
            }
            self.handle(client)
        }
    }

    private func handle(_ client: Client) {
        // The request comes at once; a client that says nothing, or dribbles,
        // is dropped when its time is up.
        let line = SSHAskpass.readLine(
            from: client.descriptor, limit: SSHAskpass.requestLimit,
            deadline: .now + requestTimeout)
        readingClients.give()
        guard let line,
            let request = try? JSONDecoder().decode(SSHAskpass.Request.self, from: line),
            request.version == 1,
            let admitted = admittedGrant(for: request, from: client.descriptor)
        else {
            client.close()
            return
        }
        serve(request, admitted: admitted, on: client)
    }

    /// Who may ask: the grant, the ssh that connection spawned, and whether
    /// that ssh is the asker's parent — it runs its askpass itself, so anything
    /// further down is a `ProxyJump`'s inner ssh or a `ProxyCommand`'s.
    private struct Admitted {
        let grant: Grant
        let ssh: pid_t
        let isIntermediateStep: Bool
    }

    /// The live grant whose token the request carries, if the sender
    /// descends — within `ancestryLimit` — from an ssh that grant's
    /// connection spawned — and that ssh. The walk stops at Corta itself.
    private func admittedGrant(
        for request: SSHAskpass.Request, from descriptor: Int32
    ) -> Admitted? {
        let grant = state.withLock { state in
            state.grants.first { SSHAskpass.tokensMatch($0.key, request.token) }?.value.grant
        }
        guard let grant else { return nil }
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0 else {
            return nil
        }
        var ancestor = record(peer)?.parent
        for generation in 1...Self.ancestryLimit {
            guard let pid = ancestor, pid > 1 else { return nil }
            if grant.admits(pid) {
                return Admitted(grant: grant, ssh: pid, isIntermediateStep: generation > 1)
            }
            guard pid != ownProcess else { return nil }
            ancestor = record(pid)?.parent
        }
        return nil
    }

    /// A refused password is a cancelled connection: OpenSSH reads a failed
    /// askpass as an empty answer, tries it, and asks again — up to
    /// `NumberOfPasswordPrompts` times, and again for keyboard-interactive.
    /// So the connection's ssh is ended, if it is still the very process that
    /// was admitted. A refused host key or confirmation needs nothing: ssh
    /// stops on its own; a refused passphrase skips its key
    /// (`SSHAskpass.refusalEndsConnection`).
    private func serve(_ request: SSHAskpass.Request, admitted: Admitted, on client: Client) {
        let grant = admitted.grant, ssh = admitted.ssh
        let refusalEnds = SSHAskpass.refusalEndsConnection(kind: request.kind, prompt: request.prompt)
        let asking = SSHAskpass.Asking(
            question: SSHAskpass.question(kind: request.kind, prompt: request.prompt),
            host: grant.host, prompt: SSHAskpass.displayPrompt(request.prompt),
            isIntermediateStep: admitted.isIntermediateStep, refusalEndsConnection: refusalEnds)
        let question = asking.question
        let prompter = self.prompter
        let task = Task {
            await prompter(asking)
        }
        // The asker going away — ssh killed it, the connection was closed —
        // takes the dialog down with it, once; anything else it sends is
        // dropped. Everything touching the descriptor runs on its queue.
        client.watchHangup { task.cancel() }
        // ssh going first says nothing to its askpass: killed, it leaves the
        // child waiting on this socket, with nobody left to read the answer.
        let interval = askerCheckInterval
        let watcher = Task.detached {
            while !Task.isCancelled, grant.admits(ssh) {
                try? await Task.sleep(for: interval, clock: .suspending)
            }
            if !Task.isCancelled { task.cancel() }
        }
        let terminate = self.terminate
        Task.detached {
            let answer = await task.value
            watcher.cancel()
            client.queue.async {
                if !task.isCancelled, question != .notify,
                    let encoded = try? JSONEncoder().encode(SSHAskpass.Reply(answer: answer))
                {
                    client.write(encoded)
                }
                client.close()
                if !task.isCancelled, refusalEnds, answer == nil, grant.admits(ssh) {
                    terminate(ssh)
                }
            }
        }
    }

    /// One askpass connection. Its descriptor is touched only on `queue`,
    /// and closed once, after which nothing writes to it — a number the
    /// kernel may already have handed to another file.
    private final class Client: @unchecked Sendable {
        let descriptor: Int32
        let queue = DispatchQueue(label: "dev.noahqin.Corta.askpass.client")
        private var hangup: DispatchSourceRead?
        private var closed = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Once `watchHangup` runs, the source owns the descriptor: its
        /// cancel handler closes it, after the last event handler is done.
        func watchHangup(_ onHangup: @escaping @Sendable () -> Void) {
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let descriptor = self.descriptor
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, !self.closed else { return }
                var scratch = [UInt8](repeating: 0, count: 256)
                let count = recv(descriptor, &scratch, scratch.count, MSG_DONTWAIT)
                if count > 0 { return }
                if count < 0, errno == EAGAIN || errno == EINTR { return }
                // EOF or an error: the asker is gone. Closing stops the
                // source too, or the readable EOF would fire on every pass.
                self.close()
                onHangup()
            }
            hangup = source
            source.resume()
        }

        func write(_ data: Data) {
            guard !closed else { return }
            _ = SSHAskpass.writeLine(data, to: descriptor)
        }

        /// On `queue`, once; later calls and writes do nothing.
        func close() {
            guard !closed else { return }
            closed = true
            if let hangup {
                hangup.cancel()
                self.hangup = nil
            } else {
                Darwin.close(descriptor)
            }
        }
    }

    /// The parent and start time of `pid`, from the kernel.
    static func processRecord(of pid: pid_t) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessRecord(
            parent: pid_t(info.pbi_ppid),
            started: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }
}
