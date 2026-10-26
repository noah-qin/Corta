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

import AppKit
import CortaPOSIX

/// What a pane says once its session has ended, as a `PaneStatusPanel`:
/// what ended, how, and what starting again costs. Nothing guesses why a
/// program ended beyond what its exit says — except ssh's 255, which is
/// ssh's own code for a connection that failed or dropped.
///
/// It is not drawn into the grid and nothing is written to the PTY, so
/// copy, search and export still see only what the program wrote.
enum SessionEnded {
    /// The panel's words and symbol for an exit.
    /// - Parameters:
    ///   - exit: the session child's final status or signal.
    ///   - isConnection: the pane ran a remote launcher; Reconnect follows.
    ///   - host: where it was connected, when known.
    ///   - program: the launcher or shell, by name (`ssh`, `zsh`).
    static func content(
        for exit: ProcessExit, isConnection: Bool, host: String?, program: String
    ) -> PaneStatusPanel.Content {
        if isConnection {
            return connectionContent(for: exit, host: host, program: program)
        }
        let title = L10n.format("session.ended.local.title", program)
        let note = L10n.text("session.ended.local.note")
        switch exit {
        case .exited(let code) where code == 0:
            return .init(symbol: "checkmark.circle", tint: .systemGreen, title: title,
                         body: L10n.text("session.ended.local.normal"), note: note)
        case .exited(let code):
            return .init(symbol: "exclamationmark.circle", tint: .systemOrange, title: title,
                         body: L10n.format("session.ended.local.code", Int(code)), note: note)
        case .signalled(let signal):
            return .init(symbol: "exclamationmark.circle", tint: .systemOrange, title: title,
                         body: L10n.format("session.ended.local.signal", signalName(signal), Int(signal)),
                         note: note)
        }
    }

    private static func connectionContent(
        for exit: ProcessExit, host: String?, program: String
    ) -> PaneStatusPanel.Content {
        let note = L10n.text("session.ended.connection.note")
        func title(_ key: String) -> String {
            host.map { L10n.format(key + ".host", $0) } ?? L10n.text(key)
        }
        switch exit {
        case .exited(let code) where code == 0:
            return .init(symbol: "checkmark.circle", tint: .systemGreen,
                         title: title("session.ended.connection.closed"),
                         body: L10n.text("session.ended.connection.normal"), note: note)
        case .exited(let code):
            let body = code == 255 && program == "ssh"
                ? L10n.text("session.ended.connection.ssh255")
                : L10n.format("session.ended.connection.code", program, Int(code))
            return .init(symbol: "network.slash", tint: .systemOrange,
                         title: title("session.ended.connection.ended"), body: body, note: note)
        case .signalled(let signal):
            return .init(symbol: "network.slash", tint: .systemOrange,
                         title: title("session.ended.connection.terminated"),
                         body: L10n.format(
                             "session.ended.connection.signal", program, signalName(signal), Int(signal)),
                         note: note)
        }
    }

    /// `SIGTERM`, `SIGKILL`, …; the number alone for one without a name.
    nonisolated static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
            SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE",
            SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM",
            SIGTERM: "SIGTERM", SIGUSR1: "SIGUSR1", SIGUSR2: "SIGUSR2", SIGXCPU: "SIGXCPU",
        ]
        return names[signal] ?? "signal \(signal)"
    }
}
