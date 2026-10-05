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
import Foundation

/// Spawning a pane's child: the fallback ladder for an ordinary start, and
/// the exact command for a Reconnect.
enum PaneSpawn {
    struct Started {
        let session: TerminalSession
        /// A fallback was used, and the pane says so.
        let notice: String?
        /// The rung that succeeded, for `PaneRemoteState` and Reconnect.
        let executable: String
        let arguments: [String]
    }

    /// Degrades rather than fails: `$SHELL` and the directory can each be stale
    /// (uninstalled shell, unmounted volume), and neither alone may abort the
    /// pane. Each is dropped in turn; `/bin/sh` in `/` is guaranteed by POSIX.
    /// - Parameter configuredShell: a parameter so tests can stage a missing
    ///   shell without setting `$SHELL` for anything else.
    static func start(
        size: TerminalSize, directory: String?, scrollbackLimit: Int,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity, preset: Preset? = nil,
        configuredShell: String? = nil, directoryCompletion: Bool = true
    ) throws(PTYError) -> Started {
        // An uninstalled preset shell degrades to a working terminal.
        let configured =
            preset?.shell ?? configuredShell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments = preset.map { $0.arguments.isEmpty ? ["-l"] : $0.arguments } ?? ["-l"]
        // A preset adds and overrides, never removes (`SECURITY.md` §4.3).
        var environment = ChildEnvironment.default()
        for (key, value) in preset?.environment ?? [:] { environment[key] = value }
        let home = NSHomeDirectory()
        // From Finder the app's cwd is "/"; start where a login shell would.
        let preferred = preset?.directory ?? directory ?? home
        let attempts: [(shell: String, directory: String, notice: String?)] = [
            (configured, preferred, nil),
            (configured, home, L10n.text("failure.notice.fallbackDirectory")),
            ("/bin/zsh", preferred, L10n.format("failure.notice.fallbackShell", "/bin/zsh")),
            ("/bin/zsh", home, L10n.format("failure.notice.fallbackShell", "/bin/zsh")),
            ("/bin/sh", "/", L10n.format("failure.notice.fallbackShell", "/bin/sh")),
        ]
        var attempted = Set<String>()
        var lastError = PTYError.spawnFailed(code: ENOENT)
        for attempt in attempts {
            // Identical rungs only delay the failure view.
            guard attempted.insert("\(attempt.shell)\u{0}\(attempt.directory)").inserted
            else { continue }
            do {
                let session = try TerminalSession(
                    executable: attempt.shell,
                    // Only for the preset's own shell; a fallback may not understand them.
                    arguments: attempt.shell == configured ? arguments : ["-l"],
                    environment: directoryCompletion
                        ? ZshBootstrap.environment(environment, executable: attempt.shell,
                            arguments: attempt.shell == configured ? arguments : ["-l"])
                        : environment, size: size,
                    workingDirectory: attempt.directory,
                    // Applies to new sessions: shrinking a live one would drop lines.
                    scrollbackLimit: scrollbackLimit, commandHistoryLimit: commandHistoryLimit)
                return Started(
                    session: session, notice: attempt.notice,
                    executable: attempt.shell,
                    arguments: attempt.shell == configured ? arguments : ["-l"])
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The recorded command, exactly — a fallback would silently turn a remote
    /// pane into a local shell.
    static func respawn(
        _ command: (executable: String, arguments: [String]),
        size: TerminalSize, configuration: Configuration, preset: Preset?,
        workingDirectory: String?
    ) throws(PTYError) -> TerminalSession {
        var environment = ChildEnvironment.default()
        for (key, value) in preset?.environment ?? [:] { environment[key] = value }
        // A local cwd for the launcher; the remote side lands where it lands.
        return try TerminalSession(
            executable: command.executable, arguments: command.arguments,
            environment: configuration.directoryCompletion
                ? ZshBootstrap.environment(environment, executable: command.executable, arguments: command.arguments)
                : environment, size: size,
            workingDirectory: preset?.directory ?? workingDirectory ?? NSHomeDirectory(),
            scrollbackLimit: configuration.scrollbackLines,
            commandHistoryLimit: configuration.commandHistoryLimit)
    }

    /// Casts to `PTYError`, not `CustomStringConvertible`: every `Error` now
    /// conforms to that, so the `localizedDescription` fallback would never run.
    static func describe(_ error: Error) -> String {
        (error as? PTYError)?.description ?? error.localizedDescription
    }
}
