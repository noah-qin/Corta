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

    /// Every file the hooks go into. bash needs two: Corta starts the shell
    /// with `-l`, and a login bash reads its login file and never `~/.bashrc`,
    /// while a bash started inside the session reads only `~/.bashrc`. The
    /// block guards itself against running twice when one sources the other.
    var rcFileURLs: [URL] {
        switch self {
        case .zsh, .fish: return [defaultRCFileURL]
        case .bash: return [defaultRCFileURL, Self.bashLoginFile(in: AppPaths.userHomeDirectory)]
        }
    }

    /// Files an earlier install may have used that are not targets now:
    /// bash's other login candidates, since which one bash reads changes as
    /// the user creates them. Checked by `status()` and cleared by Remove.
    var otherRCFileURLs: [URL] {
        guard self == .bash else { return [] }
        let targets = Set(rcFileURLs.map(\.path))
        return Self.bashLoginCandidates(in: AppPaths.userHomeDirectory).filter {
            !targets.contains($0.path)
        }
    }

    /// The file a login bash reads: the first of `~/.bash_profile`,
    /// `~/.bash_login` and `~/.profile` that exists — bash moves on only from
    /// a missing one; an unreadable one ends its search — or a new
    /// `~/.bash_profile` when none does. Read at each use: the answer changes
    /// when the user creates one of them.
    static func bashLoginFile(
        in home: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let candidates = bashLoginCandidates(in: home)
        return candidates.first { exists($0.path) } ?? candidates[0]
    }

    private static func bashLoginCandidates(in home: URL) -> [URL] {
        [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
    }
}

/// Shell integration across every file a shell needs it in: one
/// installer per file, reported and changed as one.
struct ShellIntegration {
    /// Where the hooks go now (`ShellKind.rcFileURLs`).
    let targets: [ShellIntegrationInstaller]
    /// Where an earlier install may have put them (`otherRCFileURLs`).
    let others: [ShellIntegrationInstaller]

    init(targets: [ShellIntegrationInstaller], others: [ShellIntegrationInstaller] = []) {
        self.targets = targets
        self.others = others
    }

    init(shell: ShellKind) {
        self.init(
            targets: shell.rcFileURLs.map { ShellIntegrationInstaller(shell: shell, rcFileURL: $0) },
            others: shell.otherRCFileURLs.map { ShellIntegrationInstaller(shell: shell, rcFileURL: $0) })
    }

    /// The login shell's, with its files worked out now.
    static var current: ShellIntegration { ShellIntegration(shell: .loginShell) }

    var displayPath: String { Self.paths(targets) }

    /// The targets still to be brought to this version's block.
    var pathsNeedingUpdate: String { Self.paths(targets.filter { $0.status() != .installed }) }

    private static func paths(_ installers: [ShellIntegrationInstaller]) -> String {
        installers.map(\.displayPath).joined(separator: ", ")
    }

    /// Installed when every target holds this version's block. Otherwise
    /// another terminal's integration anywhere is reported first — adding
    /// hooks beside it should be the user's decision — then a block in some
    /// file is outdated, since `update()` completes it.
    func status() -> ShellIntegrationStatus {
        let each = targets.map { $0.status() }
        if each.allSatisfy({ $0 == .installed }) { return .installed }
        let all = each + others.map { $0.status() }
        for status in all {
            if case .conflicting = status { return status }
        }
        if all.contains(where: { $0 == .installed || $0 == .outdated }) { return .outdated }
        return .notInstalled
    }

    /// Brings every target to this version's block — replaced where it
    /// differs, added where it is missing. Returns the files it could not
    /// write.
    @discardableResult
    func install() -> [String] {
        targets.filter { installer in
            switch installer.status() {
            case .installed: false
            case .outdated: !installer.update()
            case .notInstalled, .conflicting: !installer.install()
            }
        }.map(\.displayPath)
    }

    /// Removes the block from every file that may hold one. Returns the
    /// files it could not write.
    @discardableResult
    func uninstall() -> [String] {
        (targets + others).filter { !$0.uninstall() }.map(\.displayPath)
    }
}

/// Whether Corta's block is in the rc file.
enum ShellIntegrationStatus: Equatable {
    case notInstalled
    /// The Corta block is present.
    case installed
    /// The Corta block is present but its hooks are not this version's — an
    /// earlier version's, or edited by hand. An installed block is never
    /// rewritten behind the user's back, so a fix to the hooks reaches it
    /// only through `update()`.
    case outdated
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
        if text.contains(Self.beginMarker) {
            // A block whose end marker is gone cannot be updated in place;
            // calling it outdated would offer an Update that does nothing.
            guard let script = installedScript(in: text) else { return .installed }
            return script == shell.script ? .installed : .outdated
        }
        for entry in Self.knownConflictSignatures where text.contains(entry.signature) {
            return .conflicting(entry.name)
        }
        return .notInstalled
    }

    /// The first line of a file `install()` created, which is how
    /// `uninstall()` knows it may delete the file again.
    private static let createdHeader =
        "# Created by Corta for its shell integration; removing it in Settings deletes this file."

    /// Appends the block; idempotent, never doubling the hooks. A file that
    /// does not exist yet is created with `createdHeader` above the block.
    @discardableResult
    func install() -> Bool {
        let created = !FileManager.default.fileExists(atPath: rcFileURL.path)
        var existing = (try? String(contentsOf: rcFileURL, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.beginMarker) else { return true }
        if created { existing = Self.createdHeader + "\n" }
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        let block = "\n\(Self.beginMarker)\n\(shell.script)\n\(Self.endMarker)\n"
        return write(existing + block)
    }

    /// Replaces an installed block's hooks with this version's, in place: a
    /// block moved to the end would run after lines the user put below it.
    /// Everything between the markers is replaced, edits included. Fails
    /// when there is no whole block to replace.
    @discardableResult
    func update() -> Bool {
        guard let existing = try? String(contentsOf: rcFileURL, encoding: .utf8),
            let range = scriptRange(in: existing)
        else { return false }
        var updated = existing
        updated.replaceSubrange(range, with: shell.script)
        return write(updated)
    }

    /// Between the marker lines, without the newlines that frame it.
    private func installedScript(in text: String) -> String? {
        scriptRange(in: text).map { String(text[$0]) }
    }

    private func scriptRange(in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: Self.beginMarker + "\n"),
            let end = text.range(of: "\n" + Self.endMarker, range: begin.upperBound..<text.endIndex)
        else { return nil }
        return begin.upperBound..<end.lowerBound
    }

    /// Removes exactly the block `install()` wrote, with its separator line,
    /// and nothing the user added; succeeds when there is nothing to remove.
    /// A file `install()` created, left with nothing but its header, is
    /// deleted — an empty `~/.bash_profile` would hide `~/.profile` from
    /// bash for good. A file the user made, even an empty one, is kept, and
    /// a symbolic link is never deleted.
    @discardableResult
    func uninstall() -> Bool {
        guard let existing = try? String(contentsOf: rcFileURL, encoding: .utf8) else {
            return true
        }
        guard let range = blockRange(in: existing) else { return true }
        var updated = existing
        updated.removeSubrange(range)
        let remainder = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder == Self.createdHeader, !isSymbolicLink {
            return (try? FileManager.default.removeItem(at: rcFileURL)) != nil
        }
        return write(updated)
    }

    private var isSymbolicLink: Bool {
        (try? rcFileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
