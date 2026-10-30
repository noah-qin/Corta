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

import Foundation

/// The fixed remote command used only by opted-in Space SSH connections.
/// A UUID is the entire dynamic command vocabulary; names/output never become code.
public struct RemoteTmux: Equatable, Sendable {
    public let id: UUID
    public let token: UUID

    public init(id: UUID, token: UUID = UUID()) {
        self.id = id
        self.token = token
    }

    public var sessionName: String { "corta-" + id.uuidString.lowercased() }

    /// Exact targeting avoids tmux's prefix/pattern matching.
    public var killCommand: String { "tmux kill-session -t '=\(sessionName)'" }

    /// One environment assignment and one `ssh -R` pair, both optional.
    /// #434 does not set either. A later remote-member path may. Anything
    /// outside the token alphabet is dropped, never quoted into the command.
    public struct Extras: Equatable, Sendable {
        public var environmentName = ""
        public var environmentValue = ""
        public var reverseRemote = ""
        public var reverseLocal = ""
        /// Install a `/tmp` `corta` for this session and pass its environment into tmux.
        public var installRemoteClient = false

        public init() {}

        var hasEnvironment: Bool { !environmentName.isEmpty || !environmentValue.isEmpty }
        var hasForward: Bool { !reverseRemote.isEmpty || !reverseLocal.isEmpty }

        func accepted() -> Extras? {
            var copy = Extras()
            if hasEnvironment {
                guard Self.environmentName(environmentName), Self.token(environmentValue, max: 128) else { return nil }
                copy.environmentName = environmentName
                copy.environmentValue = environmentValue
            }
            if hasForward {
                guard Self.socket(reverseRemote), Self.socket(reverseLocal) else { return nil }
                copy.reverseRemote = reverseRemote
                copy.reverseLocal = reverseLocal
            }
            return copy
        }

        private static func environmentName(_ text: String) -> Bool {
            guard let first = text.utf8.first, (65...90).contains(first), text.utf8.count <= 32 else { return false }
            return text.utf8.dropFirst().allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
        }

        private static func token(_ text: String, max: Int) -> Bool {
            (1...max).contains(text.utf8.count) && text.utf8.allSatisfy(Self.isTokenByte)
        }

        private static func socket(_ text: String) -> Bool {
            text.hasPrefix("/") && token(text, max: 100)
        }

        private static func isTokenByte(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 46 || byte == 95 || byte == 45 || byte == 47
        }
    }

    /// `-R remote:local` when both paths are safe tokens. Otherwise nothing.
    public static func forwardArguments(_ extras: Extras) -> [String] {
        guard let safe = extras.accepted(), safe.hasForward else { return [] }
        return ["-R", safe.reverseRemote + ":" + safe.reverseLocal]
    }

    /// One SSH, no rc sourcing, no control mode and no remote files/config changes.
    /// -dP atomically creates the session; an exact has-session distinguishes
    /// an already-existing identity from a creation failure.
    /// Attaching by exact name then fails safely if it disappeared in between.
    /// Writes the remote `corta` with `printf %b`, so `$` survives into the file.
    private static func remoteClientInstaller() -> String {
        let script = [
            "#!/bin/sh",
            "op=$1; to=$2; shift 2",
            "printf %s\\n \"{\\\"op\\\":\\\"$op\\\",\\\"token\\\":\\\"$CORTA_MEMBER_TOKEN\\\",\\\"to\\\":\\\"$to\\\",\\\"body\\\":\\\"$*\\\"}\" | nc -U \"$CORTA_FORWARD\"",
        ].joined(separator: "\n")
        var escaped = ""
        for character in script {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "$": escaped += "\\$"
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "printf \"%b\" \"" + escaped + "\""
    }

    public var command: String { command(extras: Extras()) }

    public func command(extras: Extras) -> String {
        // ssh first passes this through the user's login shell. csh/tcsh cannot
        // parse a newline inside single quotes; keep the entire sh program in
        // one quoted argument, with no inner single quotes to split that run.
        let safe = extras.accepted() ?? Extras()
        let install = extras.installRemoteClient && safe.hasEnvironment && safe.hasForward
        let assignment = safe.hasEnvironment
            ? ["export \(safe.environmentName)=\(safe.environmentValue);"] : []
        let client: [String] = install ? [
            "d=/tmp/corta-\(safe.environmentValue);",
            "mkdir -p \"$d\";",
            Self.remoteClientInstaller() + " > \"$d/corta\";",
            "chmod 700 \"$d\" \"$d/corta\";",
        ] : []
        let flags = install
            ? "-e \(safe.environmentName)=\(safe.environmentValue) -e CORTA_FORWARD=\(safe.reverseRemote) -e PATH=/tmp/corta-\(safe.environmentValue):\\$PATH "
            : ""
        let script = (assignment + client + [
            "trap \"exit 129\" HUP;",
            "trap \"exit 143\" TERM;",
            "report_failure() {",
            "printf \"\\033]6973;\(token.uuidString);fail;%s;\" \"$1\";",
            "printf \"%s\" \"$2\" | LC_ALL=C head -c 1024 | od -An -v -tx1 | tr -d \" \\n\";",
            "printf \"\\007\"; };",
            "if ! command -v tmux >/dev/null 2>&1; then",
            "printf \"\\033]6973;\(token.uuidString);start;missing\\007\";",
            "exec \"${SHELL:-/bin/sh}\" -l; fi;",
            "prepared=$(tmux new-session -dP \(flags)-F corta-created -s \"\(sessionName)\" 2>&1);",
            "result=$?;",
            "if [ \"$result\" -eq 0 ]; then outcome=new;",
            "elif tmux has-session -t \"=\(sessionName)\" 2>/dev/null; then outcome=attached;",
            "else report_failure \"$result\" \"$prepared\";",
            "printf \"%s\\n\" \"$prepared\" >&2; exec \"${SHELL:-/bin/sh}\" -l; fi;",
            "printf \"\\033]6973;\(token.uuidString);start;%s\\007\" \"$outcome\";",
            "reason=$(tmux attach-session -t \"=\(sessionName)\" 2>&1 >/dev/tty);",
            "result=$?; if [ \"$result\" -eq 0 ]; then exit 0; fi;",
            "report_failure \"$result\" \"$reason\";",
            "printf \"%s\\n\" \"$reason\" >&2; exec \"${SHELL:-/bin/sh}\" -l"
        ]).joined(separator: " ")
        return "/bin/sh -c " + Self.quoted(script)
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public enum Outcome: String, Sendable { case missing, new, attached }

    /// At most one startup and one later failure, never a general OSC command channel.
    public struct Report: Equatable, Sendable {
        public fileprivate(set) var outcome: Outcome?
        public fileprivate(set) var failureStatus: Int?
        public fileprivate(set) var reason: String?
        public var established: Bool { outcome == .new || outcome == .attached }
    }

    struct Handshake: Sendable {
        /// How long an attach failure may still arrive after `start`, before any screen output.
        static let attachFailureWindow: Duration = .seconds(1)
        let token: String
        var report = Report()
        var finished = false
        var failDeadline: SuspendingClock.Instant?

        /// tmux has drawn. A later `fail` for this token is no longer an attach failure.
        mutating func noteScreenOutput() {
            guard report.established, !finished else { return }
            finished = true
        }

        mutating func testingExpireAttachFailureWindow() {
            guard failDeadline != nil else { return }
            failDeadline = SuspendingClock.now.advanced(by: .milliseconds(-1))
        }

        mutating func receive(_ payload: ArraySlice<UInt8>) {
            guard !finished, payload.count <= 2200 else { return }
            let fields = String(decoding: payload, as: UTF8.self)
                .split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0] == token else { return }
            if fields[1] == "start", fields.count == 3, report.outcome == nil,
               let outcome = Outcome(rawValue: String(fields[2])) {
                report.outcome = outcome
                if outcome == .missing {
                    finished = true
                } else {
                    failDeadline = SuspendingClock.now.advanced(by: Self.attachFailureWindow)
                }
            } else if let failure = Self.failure(from: fields) {
                // A failure before `start` is the prepare path. After `start`, only
                // the short window — and no screen output, which already finished — accepts it.
                if report.established {
                    guard let deadline = failDeadline, SuspendingClock.now < deadline else {
                        finished = true
                        return
                    }
                }
                report.failureStatus = failure.status
                report.reason = failure.reason
                finished = true
            }
        }

        private static func failure(from fields: [Substring]) -> (status: Int, reason: String)? {
            guard fields.count == 4, fields[1] == "fail",
                  let status = Int(fields[2]), (1...255).contains(status), fields[3].count <= 2048 else { return nil }
            let hex = Array(fields[3].utf8)
            guard hex.count.isMultiple(of: 2) else { return nil }
            var bytes: [UInt8] = []
            for offset in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[offset...offset + 1], as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(byte)
            }
            let reason = String(String(decoding: bytes, as: UTF8.self).unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !ConcealingScalars.contains($0.value)
            })
            return (status, reason)
        }
    }
}
