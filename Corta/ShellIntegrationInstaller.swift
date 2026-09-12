import Foundation

/// B07 — the shells Corta can install its integration snippet into.
enum ShellKind: String, CaseIterable {
    case zsh, bash, fish

    /// Parsed from `$SHELL`'s last path component — the login shell the
    /// user actually typed a password to get, not whatever spawned Corta.
    /// An unrecognized or missing value falls back to `zsh`, matching the
    /// only shell this ever supported before bash/fish existed.
    static var loginShell: ShellKind {
        let name = (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent
        return name.flatMap(ShellKind.init(rawValue:)) ?? .zsh
    }

    var defaultRCFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .zsh: return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bashrc")
        case .fish: return home.appendingPathComponent(".config/fish/config.fish")
        }
    }

    var script: String { ShellIntegrationScript.script(for: self) }
}

/// B07 — installs, diagnoses and removes Corta's shell integration.
///
/// Nothing in Corta requires this: a session without it falls back to
/// `TaskNotifier`'s keystroke-and-idle heuristic and greys out the menu
/// items `ViewController+ShellIntegration.swift` gates on
/// `hasShellIntegration`. This exists because most shells arrive with no
/// integration configured, and asking a new user to hand-edit their own
/// `.zshrc` with a snippet from a documentation page is the thing every
/// other terminal that ships this feature has decided not to ask.
///
/// **Inspectable and reversible**, per the roadmap issue this closes:
/// everything installed sits between two marker comments
/// (`beginMarker`/`endMarker`) in the user's own `.zshrc`, in the clear —
/// no sourced file elsewhere, nothing hidden in `~/Library`. `uninstall()`
/// removes exactly that block and nothing else, which is what makes
/// `status()` able to tell "installed" apart from "the user wrote something
/// that merely looks like it" — there is nothing to mistake, because the
/// markers are unique to Corta's own write.
enum ShellIntegrationStatus: Equatable {
    case notInstalled
    /// The Corta block is present.
    case installed
    /// No Corta block, but the rc file already sources another terminal's
    /// own shell integration — naming which one, so installing anyway is an
    /// informed choice rather than a guess about what broke.
    case conflicting(String)
}

struct ShellIntegrationInstaller {
    /// Which shell's hooks and rc file this instance targets.
    let shell: ShellKind

    /// The rc file this instance reads and writes — injected so a test can
    /// point at a temporary file instead of the user's real rc file. Never
    /// change the file a running Corta actually reads to test this
    /// (`CLAUDE.md` — "Never change the machine to test").
    let rcFileURL: URL

    init(shell: ShellKind, rcFileURL: URL) {
        self.shell = shell
        self.rcFileURL = rcFileURL
    }

    init(shell: ShellKind) {
        self.init(shell: shell, rcFileURL: shell.defaultRCFileURL)
    }

    static let shared = ShellIntegrationInstaller(shell: .loginShell)

    /// `rcFileURL` with the home directory abbreviated to `~`, for status
    /// copy — `"~/.zshrc"`, not the full path a sandboxed-looking absolute
    /// path would imply.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = rcFileURL.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static let beginMarker = "# >>> Corta shell integration >>>"
    private static let endMarker = "# <<< Corta shell integration <<<"

    /// Other terminals' own zsh integration, matched narrowly enough that a
    /// hit means something. A miss costs nothing — the user still gets a
    /// working integration — so the list stays specific rather than
    /// pattern-matching anything OSC-133-shaped, which would flag every
    /// shell that already has *some* integration, including a previous
    /// Corta install this rc file's `beginMarker` check already recognises.
    private static let knownConflictSignatures: [(signature: String, name: String)] = [
        ("iterm2_shell_integration", "iTerm2"),
        ("starship_precmd_user_func", "Starship"),
        ("__vsc_prompt_start", "Visual Studio Code"),
        ("WEZTERM_SHELL_SKIP_ALL", "WezTerm"),
    ]

    /// Whether the block is installed, absent, or absent alongside another
    /// terminal's own integration. Never throws: an unreadable or missing rc
    /// file is `.notInstalled` — there is nothing there to conflict with,
    /// and "not installed" is the honest, actionable answer either way.
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

    /// Appends the block. Idempotent: installing over an existing install
    /// changes nothing and still reports success, rather than doubling the
    /// hooks a second `source` would register.
    @discardableResult
    func install() -> Bool {
        var existing = (try? String(contentsOf: rcFileURL, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.beginMarker) else { return true }
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        let block = "\n\(Self.beginMarker)\n\(shell.script)\n\(Self.endMarker)\n"
        return write(existing + block)
    }

    /// Removes exactly the block `install()` wrote — the blank separator
    /// line before it and everything through the trailing newline after
    /// `endMarker` — and nothing a user added inside or around it. A no-op,
    /// reporting success, when there is nothing to remove.
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

    private func write(_ text: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: rcFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: rcFileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
