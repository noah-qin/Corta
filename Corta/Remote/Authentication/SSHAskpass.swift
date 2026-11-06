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
import Security

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

    /// One question, as the dialog needs it. Decided in one place, from the
    /// request as it came: what a dialog shows is cut short, and two readers
    /// of different strings could disagree about what Cancel does.
    struct Asking: Equatable, Sendable {
        var question: Question
        /// The place the connection goes, as the window names it.
        var host: String
        /// As it may be shown (`displayPrompt`).
        var prompt: String
        /// The asker is not the ssh the connection spawned but something below
        /// it: a `ProxyJump`'s inner ssh, a `ProxyCommand`. Whoever is asking,
        /// it is not `host`, and a dialog must not say it is.
        var isIntermediateStep = false
        /// Refused, the connection's ssh is ended (`refusalEndsConnection`).
        var refusalEndsConnection = false
    }

    /// ssh asks about a host key with this question at the end of its own
    /// text. A server can send the same words in a keyboard-interactive
    /// prompt, but that only makes the answer "yes" go to that server: the
    /// dialog has no field, and the two cannot be told apart from here, since
    /// a server can copy ssh's wording exactly (`SECURITY.md` §4.8).
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

    /// Whether refusing this question ends the connection: a password or a
    /// server's one-time code does. A key's passphrase does not — refused, ssh
    /// skips that key and goes on to the next, a password among them. Read
    /// from the whole prompt, once, by the broker.
    static func refusalEndsConnection(kind: Kind, prompt: String) -> Bool {
        question(kind: kind, prompt: prompt) == .secret && !prompt.lowercased().contains("passphrase")
    }

    /// A prompt as a dialog may show it. Keyboard-interactive prompts are
    /// the server's text: controls and concealing scalars become U+FFFD
    /// (as SFTP names do), and it is bounded in characters and lines.
    static func displayPrompt(_ prompt: String) -> String {
        let spaced = prompt.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let cleaned = SFTPBrowserModel.replacingConcealedScalars(
            in: spaced, with: "\u{FFFD}", keepingNewlines: true)
        var lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
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

    /// Up to the first newline, at most `limit` bytes; nil on EOF, an error,
    /// a line that does not fit, or `deadline` passing — one for the whole
    /// line, so a byte every few seconds cannot keep a reader for hours.
    static func readLine(
        from descriptor: Int32, limit: Int, deadline: SuspendingClock.Instant? = nil
    ) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count <= limit {
            if let deadline, !waitForInput(on: descriptor, until: deadline) { return nil }
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
        }
        return nil
    }

    private static func waitForInput(on descriptor: Int32, until deadline: SuspendingClock.Instant) -> Bool {
        while true {
            let remaining = SuspendingClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = remaining.components.seconds * 1000
                + remaining.components.attoseconds / 1_000_000_000_000_000 + 1
            let ready = poll(&entry, 1, Int32(clamping: milliseconds))
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return false }
        }
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
