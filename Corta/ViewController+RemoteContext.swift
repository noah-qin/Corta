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

/// The pane's live read of `PaneRemoteState`, and the honest reconnect it
/// enables.
extension ViewController {
    /// Resolved now, paying the `tcgetpgrp`/`proc_name` syscalls, for one-off
    /// questions. The title reads the cached copy
    /// (`refreshProcessFactsIfStale`), keeping syscalls off the output path.
    var paneRemoteState: PaneRemoteState {
        guard isOperable else { return .local }
        return resolveRemoteState()
    }

    /// The pane's own child is a live remote launcher, which the foreground
    /// signal can't see. Liveness is `exitStatus`: an exited `ssh` still
    /// showing output is dead, and its report stale.
    var childIsLiveRemoteLauncher: Bool {
        guard let launchedCommand,
            PaneRemoteState.isRemoteLauncher(executable: launchedCommand.executable)
        else { return false }
        return session != nil && session.pty.exitStatus == nil
    }

    // MARK: - Reconnect

    /// What actually spawned, or the preset's command if the spawn failed.
    var reconnectCommand: (executable: String, arguments: [String])? {
        if let launchedCommand { return launchedCommand }
        guard let shell = preset?.shell else { return nil }
        return (shell, preset?.arguments ?? [])
    }

    /// Only for a remote launcher whose child is gone: a local shell has Try
    /// Again, and a live `ssh` would have to be killed.
    ///
    /// No Corta-side `ControlMaster`: an opaque master process whose lifetime
    /// Corta owns, coupling panes by host. The system `/usr/bin/ssh` already
    /// honours the user's own `Control*` settings, with ssh owning the
    /// lifetime.
    var canReconnectRemote: Bool {
        guard let command = reconnectCommand,
            PaneRemoteState.isRemoteLauncher(executable: command.executable)
        else { return false }
        return session == nil || session.pty.exitStatus != nil
    }

    /// Whether the command reattaches a multiplexer (`tmux attach`,
    /// `screen -r`). Copy only: Corta never claims to restore state.
    nonisolated static func reattachesRemoteSession(_ arguments: [String]) -> Bool {
        // Words, since `ssh host "tmux attach"` is the same command.
        let words = arguments.flatMap { $0.split(separator: " ").map(String.init) }
        for (index, word) in words.enumerated() {
            let rest = words[(index + 1)...]
            switch word {
            case "tmux":
                if let verb = rest.first(where: { !$0.hasPrefix("-") }),
                    ["attach", "attach-session", "a"].contains(verb)
                { return true }
            case "screen":
                // `-r`, `-x` and combinations reattach.
                if rest.contains(where: { $0.hasPrefix("-r") || $0.hasPrefix("-x") }) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    @objc func reconnectRemote(_ sender: Any?) {
        guard canReconnectRemote else { return }
        rebuildPane(strictRespawn: true)
    }

    /// Never "restored": the process and remote state are gone. A reattach
    /// command gets the credit, attaching to whatever exists now.
    var reconnectNotice: String {
        if let command = reconnectCommand, Self.reattachesRemoteSession(command.arguments) {
            return L10n.text("toast.reconnectedReattach")
        }
        return L10n.text("toast.reconnected")
    }
}
