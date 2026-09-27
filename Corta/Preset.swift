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

/// A named way to open a terminal: a shell, a directory, arguments and
/// environment variables, as `preset.<name>.…` keys. Applied at spawn only,
/// so a preset pane is an ordinary pane afterwards. Not a profile: colours,
/// fonts and keybindings stay app-wide (`DESIGN.md` §6), or this would be a
/// second settings store.
///
/// **ssh presets** (`shell = /usr/bin/ssh`, `arguments = user@host`) use
/// the system OpenSSH, so the user's agent and `~/.ssh/config` apply. The
/// pane is remote from its spawn record (`PaneRemoteState`), and when the
/// connection dies Reconnect re-runs the same command as a new connection.
/// `directory` is still the launcher's local directory.
nonisolated struct Preset: Equatable, Sendable {
    /// The key name, shown in the menu.
    var name: String
    /// An absolute shell path; nil inherits `$SHELL`.
    var shell: String?
    /// Empty inherits the login-shell default.
    var arguments: [String] = []
    /// An absolute path; nil inherits the split-from directory, or home.
    var directory: String?
    /// Added over the sanitised environment (`SECURITY.md` §4.3); a preset
    /// can add and override, never remove.
    var environment: [String: String] = [:]

    init(name: String) {
        self.name = name
    }

    /// A name with no settings is a typo, not a menu item.
    var isEmpty: Bool {
        shell == nil && directory == nil && arguments.isEmpty && environment.isEmpty
    }

    /// Shell and directory must be absolute: a relative directory resolves
    /// against Corta's own, `/` from Finder.
    var isUsable: Bool {
        guard !isEmpty else { return false }
        if let shell, !shell.hasPrefix("/") { return false }
        if let directory, !directory.hasPrefix("/") { return false }
        return true
    }

    /// Applies one `preset.<name>.<field>`; false keeps it as an unknown key.
    mutating func apply(field: String, value: String) -> Bool {
        if field.hasPrefix("env.") {
            let variable = String(field.dropFirst("env.".count))
            // `=` or NUL can't be in an environment name.
            guard !variable.isEmpty, !variable.contains("="), !variable.contains("\0")
            else { return false }
            environment[variable] = value
            return true
        }
        switch field {
        case "shell":
            shell = value.isEmpty ? nil : value
        case "directory":
            directory = value.isEmpty ? nil : (value as NSString).expandingTildeInPath
        case "arguments":
            // Space-separated; anything needing quotes belongs in a script.
            arguments = value.split(separator: " ").map(String.init)
        default:
            return false
        }
        return true
    }

    var serializedLines: [String] {
        var lines: [String] = []
        if let shell { lines.append("preset.\(name).shell = \(shell)") }
        if !arguments.isEmpty {
            lines.append("preset.\(name).arguments = \(arguments.joined(separator: " "))")
        }
        if let directory { lines.append("preset.\(name).directory = \(directory)") }
        for key in environment.keys.sorted() {
            lines.append("preset.\(name).env.\(key) = \(environment[key] ?? "")")
        }
        return lines
    }
}
