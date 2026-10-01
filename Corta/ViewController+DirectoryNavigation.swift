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

import Cocoa
import CortaTerminal

/// App-initiated `cd` through shell integration, and its safety gate.
extension ViewController {
    /// Whether this pane can safely receive an app-initiated `cd` now:
    ///
    /// - **Pane identity**: a live session (`isOperable`).
    /// - **Remote context**: a remote path is fine for the pane's own remote
    ///   shell. It must never reach a local spawn, which is structural:
    ///   spawns read `session.workingDirectory`, kept local-only by
    ///   `Performer+OSC.swift`, while remote reports live in `remoteContext`.
    /// - **Prompt state**: `hasShellIntegration` and `!isCommandRunning` — a
    ///   busy shell or a TUI must not get prompt input.
    /// - **Existing input**: the cursor is still at `promptEndPosition`, so
    ///   nothing the user typed gets a `cd` spliced into it.
    var canChangeDirectorySafely: Bool {
        guard isOperable, session.hasShellIntegration, !session.isCommandRunning else {
            return false
        }
        guard let end = session.promptEndPosition else { return false }
        let grid = session.snapshot()
        guard let screenRow = grid.screenRow(ofAbsoluteRow: end.row) else { return false }
        return grid.cursor.row == screenRow && grid.cursor.column == end.column
    }

    /// Where this pane's shell actually is: local when local, the reported
    /// remote directory (with host) when remote, nil when neither is known.
    /// Only for `changeDirectory(to:)`; local spawns and Finder read
    /// `session.workingDirectory`.
    var shellDirectory: (path: String, host: String?)? {
        switch paneRemoteState {
        case .remote(let host, let directory, _):
            return (directory, host)
        case .local:
            return session.workingDirectory.map { ($0, nil) }
        case .remoteUnknown, .unknown:
            // Remote without a report, or a multiplexer: the local directory is
            // stale, and sending it to another machine's shell is a leak.
            return nil
        }
    }

    /// Writes `cd '<path>'` and Return under `canChangeDirectorySafely`;
    /// returns whether it did.
    ///
    /// The path began as child-sent OSC 7 text, which `SECURITY.md` §6 says
    /// never to write back. It goes back only as the user's command: sent on
    /// their own action to the shell on the path's machine, quoted for any
    /// shell (`shellQuoted` — fish reads `'\''` differently), and refused
    /// outright if it holds a control character, the one shape another shell
    /// could read as two commands.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely, Self.isSendableDirectoryPath(path) else { return false }
        session.write(Array("cd \(Self.shellQuoted(path))\r".utf8))
        return true
    }

    /// Non-empty, with nothing from C0 or C1.
    nonisolated static func isSendableDirectoryPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            }
    }
}
