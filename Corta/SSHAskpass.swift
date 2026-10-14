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

import CortaTerminal
import Darwin
import Foundation
import Security
import Synchronization

/// How an SFTP connection's `ssh` asks the user something (D27).
///
/// The channel has no terminal, so OpenSSH's own `SSH_ASKPASS` is the only
/// way it can ask for a password, a key passphrase, a one-time code or
/// whether to trust a new host key. With `SSH_ASKPASS_REQUIRE=force`, ssh
/// runs the program `SSH_ASKPASS` names with the question as its argument
/// and reads the answer from its output. That program is Corta's own
/// executable (`SSHAskpassClient`): it carries the question over a socket to
/// the running app (`SSHAskpassBroker`), which asks in a dialog
/// (`SSHAskpassPrompter`) and hands the answer back. Nothing is stored.
nonisolated enum SSHAskpass {
    /// The socket and the connection's token, in the ssh child's environment
    /// only: `ChildEnvironment` strips every `CORTA_` name from a shell's.
    static let socketVariable = "CORTA_ASKPASS_SOCKET"
    static let tokenVariable = "CORTA_ASKPASS_TOKEN"

    /// A request is one line; a prompt longer than this is not a question.
    static let requestLimit = 16 * 1024
    /// What a dialog shows of a prompt, in characters.
    static let promptLimit = 2000
    static let promptLineLimit = 24

    /// What ssh asked for, from `SSH_ASKPASS_PROMPT`: an answer (unset), a
    /// yes or no (`confirm`, an agent key's use), or nothing — a notice
    /// shown until ssh is done with it (`none`, touch a security key).
    enum Kind: String, Codable, Sendable {
        case secret, confirm, notify

        init(promptVariable: String?) {
            switch promptVariable {
            case "confirm": self = .confirm
            case "none": self = .notify
            default: self = .secret
            }
        }
    }

    struct Request: Codable, Equatable, Sendable {
        var version = 1
        var token: String
        var kind: Kind
        var prompt: String
    }

    /// `answer` nil is a refusal: the client exits non-zero, which ssh
    /// takes as cancelled.
    struct Reply: Codable, Equatable, Sendable {
        var answer: String?
    }

    /// The dialog a request becomes.
    enum Question: Equatable, Sendable {
        /// Typed and hidden: a password, a passphrase, a one-time code.
        case secret
        /// ssh's own question about a host key it has not seen, or one that
        /// changed in a way it lets the user accept: "yes" or nothing.
        case hostKey
        case confirm
        case notify
    }

    /// ssh asks about a host key with this question at the end of its own
    /// text. A server can send the same words in a keyboard-interactive
    /// prompt, but that only makes the answer "yes" go to that server.
    static func question(kind: Kind, prompt: String) -> Question {
        switch kind {
        case .confirm: return .confirm
        case .notify: return .notify
        case .secret:
            let ending = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return ending.hasSuffix("(yes/no/[fingerprint])?") || ending.hasSuffix("(yes/no)?")
                ? .hostKey : .secret
        }
    }

    /// A prompt as a dialog may show it. Keyboard-interactive prompts are
    /// the server's text: controls and concealing scalars become U+FFFD
    /// (as SFTP names do), and it is bounded in characters and lines.
    static func displayPrompt(_ prompt: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in prompt.unicodeScalars {
            if scalar == "\n" {
                scalars.append(scalar)
            } else if scalar == "\r" || scalar == "\t" {
                scalars.append(" ")
            } else if CharacterSet.controlCharacters.contains(scalar)
                || ConcealingScalars.contains(scalar.value)
            {
                scalars.append("\u{FFFD}")
            } else {
                scalars.append(scalar)
            }
        }
        var lines = String(scalars).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var text = lines.prefix(promptLineLimit).joined(separator: "\n")
        if lines.count > promptLineLimit || text.count > promptLimit {
            text = String(text.prefix(promptLimit)) + "…"
        }
        return text
    }

    /// The environment that makes ssh ask through `executable`.
    static func environment(executable: String, socketPath: String, token: String) -> [String: String] {
        [
            "SSH_ASKPASS": executable,
            "SSH_ASKPASS_REQUIRE": "force",
            socketVariable: socketPath,
            tokenVariable: token,
        ]
    }

    /// 32 random bytes as hex. Nil only if the system generator fails, and
    /// then there is no askpass rather than a guessable one.
    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Equal without saying, by how long it took, how much was.
    static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    // MARK: - Lines over a socket

    static func writeLine(_ data: Data, to descriptor: Int32) -> Bool {
        var bytes = data
        bytes.append(UInt8(ascii: "\n"))
        return bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Up to the first newline, at most `limit` bytes; nil on EOF, an error
    /// or a line that does not fit.
    static func readLine(from descriptor: Int32, limit: Int) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count <= limit {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
        }
        return nil
    }

    static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

// MARK: - The askpass program

/// Corta's executable started by ssh as `SSH_ASKPASS`: carries the question
/// to the app and prints the answer. Runs before `NSApplication` exists, so
/// it never shows in the Dock; anything but an answer exits non-zero, which
/// ssh treats as the question cancelled.
nonisolated enum SSHAskpassClient {
    /// The exit status when this process is ssh's askpass, nil otherwise.
    static func runIfInvoked(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard let path = environment[SSHAskpass.socketVariable],
            let token = environment[SSHAskpass.tokenVariable]
        else { return nil }
        let request = SSHAskpass.Request(
            token: token, kind: SSHAskpass.Kind(promptVariable: environment["SSH_ASKPASS_PROMPT"]),
            prompt: arguments.dropFirst().first ?? "")
        guard let reply = exchange(request, socketPath: path), let answer = reply.answer else {
            return 1
        }
        if request.kind != .notify {
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        }
        return 0
    }

    /// One request, one reply. A notice is never answered: the read waits
    /// until ssh, done with it, ends this process.
    static func exchange(_ request: SSHAskpass.Request, socketPath: String) -> SSHAskpass.Reply? {
        guard var address = SSHAskpass.socketAddress(socketPath),
            let encoded = try? JSONEncoder().encode(request)
        else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, SSHAskpass.writeLine(encoded, to: descriptor),
            let line = SSHAskpass.readLine(from: descriptor, limit: SSHAskpass.requestLimit)
        else { return nil }
        return try? JSONDecoder().decode(SSHAskpass.Reply.self, from: line)
    }
}

// MARK: - The app's end

/// Listens for askpass requests and answers each through `prompter`.
///
/// A request is answered only when all of these hold (`SECURITY.md` §4.8):
/// it arrives on a socket in a `0700` directory of the user's own
/// temporary folder; it carries the token of a live grant, compared in
/// constant time; and the process sending it is the child of an ssh that
/// grant's connection spawned (`LOCAL_PEERPID`, then its parent). The token
/// alone is in ssh's environment, which the same user's processes can read;
/// the parent check is what ties a request to that ssh.
nonisolated final class SSHAskpassBroker: @unchecked Sendable {
    /// Asks the user; nil is a refusal. Cancelled when the asking process
    /// goes away — ssh gave up, or the connection was closed.
    typealias Prompter = @Sendable (_ question: SSHAskpass.Question, _ host: String, _ prompt: String) async -> String?

    static let shared = SSHAskpassBroker(
        executable: Bundle.main.executablePath,
        prompter: { question, host, prompt in
            await SSHAskpassPrompter.ask(question, host: host, prompt: prompt)
        })

    /// A connection's permission to ask: its token, the host its dialogs
    /// name, and the ssh processes it spawned. Held by the connection; the
    /// broker keeps it weakly, so a closed connection can ask nothing.
    final class Grant: Sendable {
        let token: String
        let host: String
        let environment: [String: String]
        private let processes = Mutex(Set<pid_t>())

        fileprivate init(token: String, host: String, environment: [String: String]) {
            self.token = token
            self.host = host
            self.environment = environment
        }

        /// An ssh this connection spawned, whose askpass may ask.
        func admit(_ pid: pid_t) {
            processes.withLock { _ = $0.insert(pid) }
        }

        func admits(_ pid: pid_t) -> Bool {
            processes.withLock { $0.contains(pid) }
        }
    }

    private struct WeakGrant {
        weak var grant: Grant?
    }

    private struct State {
        var listener: Int32 = -1
        var source: DispatchSourceRead?
        var directory: String?
        var socketPath: String?
        var grants: [String: WeakGrant] = [:]
        var failed = false
    }

    private let executable: String?
    private let prompter: Prompter
    /// The parent of a process; injected so tests can stand in for ssh.
    private let parentOf: @Sendable (pid_t) -> pid_t?
    private let queue = DispatchQueue(label: "dev.noahqin.Corta.askpass")
    private let state = Mutex(State())

    init(
        executable: String?, prompter: @escaping Prompter,
        parentOf: @escaping @Sendable (pid_t) -> pid_t? = SSHAskpassBroker.parentProcess(of:)
    ) {
        self.executable = executable
        self.prompter = prompter
        self.parentOf = parentOf
    }

    deinit {
        stop()
    }

    /// A grant for one connection to `host`, listening first if this is the
    /// first. Nil when the socket cannot be set up — the connection then
    /// runs without askpass and fails to sign in as it always did.
    func grant(host: String) -> Grant? {
        guard let executable, let socketPath = listen(), let token = SSHAskpass.makeToken() else {
            return nil
        }
        let grant = Grant(
            token: token, host: host,
            environment: SSHAskpass.environment(
                executable: executable, socketPath: socketPath, token: token))
        state.withLock { state in
            state.grants = state.grants.filter { $0.value.grant != nil }
            state.grants[token] = WeakGrant(grant: grant)
        }
        return grant
    }

    /// Closes the socket and removes its directory.
    func stop() {
        let (source, directory, path) = state.withLock { state in
            defer {
                state.source = nil
                state.listener = -1
                state.directory = nil
                state.socketPath = nil
            }
            return (state.source, state.directory, state.socketPath)
        }
        source?.cancel()
        if let path { unlink(path) }
        if let directory { rmdir(directory) }
    }

    // MARK: Listening

    private func listen() -> String? {
        state.withLock { state -> String? in
            if let path = state.socketPath { return path }
            guard !state.failed else { return nil }
            // A fresh 0700 directory in the per-user temporary folder: no
            // other user can reach the socket, and nothing stale is reused.
            let template = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("corta-askpass.XXXXXX")
            var buffer = Array(template.utf8CString)
            guard let made = mkdtemp(&buffer) else { state.failed = true; return nil }
            let directory = String(cString: made)
            let path = (directory as NSString).appendingPathComponent("s")
            guard var address = SSHAskpass.socketAddress(path) else {
                rmdir(directory)
                state.failed = true
                return nil
            }
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else {
                rmdir(directory)
                state.failed = true
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
                state.failed = true
                return nil
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptOne(on: listener) }
            source.setCancelHandler { close(listener) }
            source.resume()
            state.listener = listener
            state.source = source
            state.directory = directory
            state.socketPath = path
            return path
        }
    }

    private func acceptOne(on listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // The request comes at once; a client that says nothing is dropped.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = SSHAskpass.readLine(from: client, limit: SSHAskpass.requestLimit),
            let request = try? JSONDecoder().decode(SSHAskpass.Request.self, from: line),
            request.version == 1,
            let grant = admittedGrant(for: request, from: client)
        else {
            close(client)
            return
        }
        serve(request, grant: grant, on: client)
    }

    /// The live grant whose token the request carries, if the sender is the
    /// child of an ssh that grant's connection spawned.
    private func admittedGrant(for request: SSHAskpass.Request, from client: Int32) -> Grant? {
        let grant = state.withLock { state in
            state.grants.first { SSHAskpass.tokensMatch($0.key, request.token) }?.value.grant
        }
        guard let grant else { return nil }
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0,
            let parent = parentOf(peer)
        else { return nil }
        // ssh is spawned before it can ask anything, but the pid is recorded
        // just after `posix_spawn` returns: allow that moment to pass.
        for _ in 0..<50 {
            if grant.admits(parent) { return grant }
            usleep(20_000)
        }
        return nil
    }

    private func serve(_ request: SSHAskpass.Request, grant: Grant, on client: Int32) {
        let question = SSHAskpass.question(kind: request.kind, prompt: request.prompt)
        let prompt = SSHAskpass.displayPrompt(request.prompt)
        let prompter = self.prompter
        let host = grant.host
        let task = Task {
            await prompter(question, host, prompt)
        }
        // The asker going away — ssh killed it, the connection was closed —
        // takes the dialog down with it. Anything else it sends is dropped.
        let hangup = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        hangup.setEventHandler {
            var scratch = [UInt8](repeating: 0, count: 256)
            if recv(client, &scratch, scratch.count, MSG_DONTWAIT) <= 0 { task.cancel() }
        }
        // The descriptor outlives every handler: closed only once the source
        // is cancelled, never under it.
        hangup.setCancelHandler { close(client) }
        hangup.resume()
        let reply = SendableSource(source: hangup)
        Task.detached { [queue] in
            let answer = await task.value
            queue.async {
                if !task.isCancelled, question != .notify,
                    let encoded = try? JSONEncoder().encode(SSHAskpass.Reply(answer: answer))
                {
                    _ = SSHAskpass.writeLine(encoded, to: client)
                }
                reply.source.cancel()
            }
        }
    }

    private struct SendableSource: @unchecked Sendable {
        let source: DispatchSourceRead
    }

    /// The parent of `pid`, from the kernel.
    static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
