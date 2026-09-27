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

/// The shells Corta can install its integration snippet into.
enum ShellKind: String, CaseIterable {
    case zsh, bash, fish

    /// From `$SHELL`'s last component; unknown or missing means `zsh`.
    static var loginShell: ShellKind {
        let name = (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent
        return name.flatMap(ShellKind.init(rawValue:)) ?? .zsh
    }

    /// The rc file under `AppPaths.userHomeDirectory`: the stage directory for
    /// a Debug build, so it never edits the user's real rc file (D22).
    var defaultRCFileURL: URL {
        let home = AppPaths.userHomeDirectory
        switch self {
        case .zsh: return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bashrc")
        case .fish: return home.appendingPathComponent(".config/fish/config.fish")
        }
    }

    var script: String { ShellIntegrationScript.script(for: self) }
}

/// Whether Corta's block is in the rc file.
enum ShellIntegrationStatus: Equatable {
    case notInstalled
    /// The Corta block is present.
    case installed
    /// No Corta block, but another terminal's integration (named) is sourced.
    case conflicting(String)
}

/// Installs, diagnoses and removes shell integration, which is optional:
/// without it `TaskNotifier` falls back to a heuristic and the gated menu
/// items grey out. It spares users hand-editing their rc file.
///
/// Everything sits between two marker comments in the user's own rc file,
/// in the clear; `uninstall()` removes exactly that block, and the unique
/// markers let `status()` tell it from look-alikes.
struct ShellIntegrationInstaller {
    /// Which shell's hooks and rc file this targets.
    let shell: ShellKind

    /// Injected so tests use a temporary file (D13).
    let rcFileURL: URL

    init(shell: ShellKind, rcFileURL: URL) {
        self.shell = shell
        self.rcFileURL = rcFileURL
    }

    init(shell: ShellKind) {
        self.init(shell: shell, rcFileURL: shell.defaultRCFileURL)
    }

    static let shared = ShellIntegrationInstaller(shell: .loginShell)

    /// `rcFileURL` with the user's home as `~`. A staged build's rc file is
    /// shown in full, making plain it isn't the one real shells read (D22).
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = rcFileURL.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static let beginMarker = "# >>> Corta shell integration >>>"
    private static let endMarker = "# <<< Corta shell integration <<<"

    /// Other terminals' integrations, matched narrowly: a miss costs nothing,
    /// while anything OSC-133-shaped would flag every integrated shell.
    private static let knownConflictSignatures: [(signature: String, name: String)] = [
        ("iterm2_shell_integration", "iTerm2"),
        ("starship_precmd_user_func", "Starship"),
        ("__vsc_prompt_start", "Visual Studio Code"),
        ("WEZTERM_SHELL_SKIP_ALL", "WezTerm"),
    ]

    /// Never throws: an unreadable or missing rc file is `.notInstalled`.
    func status() -> ShellIntegrationStatus {
        guard let text = try? String(contentsOf: rcFileURL, encoding: .utf8) else {
            return .notInstalled
        }
        if text.contains(Self.beginMarker) { return .installed }
        for entry in Self.knownConflictSignatures where text.contains(entry.signature) {
            return .conflicting(entry.name)
        }
        return .notInstalled
    }

    /// Appends the block; idempotent, never doubling the hooks.
    @discardableResult
    func install() -> Bool {
        var existing = (try? String(contentsOf: rcFileURL, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.beginMarker) else { return true }
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        let block = "\n\(Self.beginMarker)\n\(shell.script)\n\(Self.endMarker)\n"
        return write(existing + block)
    }

    /// Removes exactly the block `install()` wrote, with its separator line,
    /// and nothing the user added; succeeds when there is nothing to remove.
    @discardableResult
    func uninstall() -> Bool {
        guard let existing = try? String(contentsOf: rcFileURL, encoding: .utf8) else {
            return true
        }
        guard let range = blockRange(in: existing) else { return true }
        var updated = existing
        updated.removeSubrange(range)
        return write(updated)
    }

    private func blockRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: Self.beginMarker),
            let end = text.range(of: Self.endMarker, range: begin.upperBound..<text.endIndex)
        else { return nil }
        var lower = begin.lowerBound
        if lower > text.startIndex {
            let before = text.index(before: lower)
            if text[before] == "\n" { lower = before }
        }
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return lower..<upper
    }

    /// Through `UserFile`, so a symlinked rc file stays a link.
    private func write(_ text: String) -> Bool {
        do {
            try UserFile.write(text, to: rcFileURL)
            return true
        } catch {
            return false
        }
    }
}
