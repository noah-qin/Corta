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

    /// One SSH, no rc sourcing, no control mode, no environment, no forwarded
    /// socket and no remote files/config changes — not even `allow-passthrough`.
    /// -dP atomically creates the session; an exact has-session distinguishes
    /// an already-existing identity from a creation failure.
    /// Attaching by exact name then fails safely if it disappeared in between.
    public var command: String {
        // ssh first passes this through the user's login shell. csh/tcsh cannot
        // parse a newline inside single quotes; keep the entire sh program in
        // one quoted argument, with no inner single quotes to split that run.
        let script = [
            "trap \"exit 129\" HUP;",
            "trap \"exit 143\" TERM;",
            "started=no; report_failure() {",
            "if [ \"$started\" != yes ]; then printf \"\\033]6973;\(token.uuidString);start;new\\007\";"
                + " started=yes; fi;",
            "printf \"\\033]6973;\(token.uuidString);fail;%s;\" \"$1\";",
            "printf \"%s\" \"$2\" | LC_ALL=C head -c 1024 | od -An -v -tx1 | tr -d \" \\n\";",
            "printf \"\\007\"; };",
            "if ! command -v tmux >/dev/null 2>&1; then",
            "printf \"\\033]6973;\(token.uuidString);start;missing\\007\";",
            "exec \"${SHELL:-/bin/sh}\" -l; fi;",
            "prepared=$(tmux new-session -dP -F corta-created -s \"\(sessionName)\" 2>&1);",
            "result=$?;",
            "if [ \"$result\" -eq 0 ]; then outcome=new;",
            "elif tmux has-session -t \"=\(sessionName)\" 2>/dev/null; then outcome=attached;",
            "else report_failure \"$result\" \"$prepared\";",
            "printf \"%s\\n\" \"$prepared\" >&2; exec \"${SHELL:-/bin/sh}\" -l; fi;",
            "started=yes; printf \"\\033]6973;\(token.uuidString);start;%s\\007\" \"$outcome\";",
            "reason=$(tmux attach-session -t \"=\(sessionName)\" 2>&1 >/dev/tty);",
            "result=$?;",
            "if [ \"$result\" -eq 0 ]; then exit 0; fi;",
            "report_failure \"$result\" \"$reason\";",
            "printf \"%s\\n\" \"$reason\" >&2; exec \"${SHELL:-/bin/sh}\" -l",
        ].joined(separator: " ")
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
        public var established: Bool { failureStatus == nil && (outcome == .new || outcome == .attached) }
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
            } else if report.outcome != nil, let failure = Self.failure(from: fields) {
                // Only a started handshake can fail; a report alone never arms it.
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
            var reason = String(String(decoding: bytes, as: UTF8.self).unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !ConcealingScalars.contains($0.value)
            })
            while reason.utf8.count > 1024 { reason.removeLast() }
            return (status, reason)
        }
    }
}
