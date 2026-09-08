import Foundation

/// U16 — a named way to open a terminal: a shell, a directory, and a few
/// environment variables.
///
/// **The problem.** Corta opens one kind of terminal: `$SHELL`, in the
/// directory the pane was split from. A person who keeps a project checkout,
/// a staging box's `ssh` and a `python` REPL open all day rebuilds those three
/// by hand every launch — `cd`, export, run — and the terminal has all three
/// pieces of information already.
///
/// **The shape.** A preset is data in the config file, not a stored session:
/// `preset.<name>.shell`, `.directory`, `.arguments`, and `.env.<KEY>`. It is
/// applied at spawn time and never afterwards, so a pane opened from a preset
/// is an ordinary pane — there is nothing to "leave", nothing to sync, and
/// closing it loses nothing a preset could have kept.
///
/// **What it deliberately is not.** Not a profile system: no colours, no
/// fonts, no per-preset keybindings. Those are window-wide or app-wide in
/// Corta by design (`DESIGN.md` §6), and a preset that changed them would be
/// a second settings store fighting the first.
nonisolated struct Preset: Equatable, Sendable {
    /// The key it is written under, and the name shown in the menu.
    var name: String
    /// An absolute path to a shell. `nil` inherits `$SHELL`, which is what
    /// a preset that only sets a directory wants.
    var shell: String?
    /// Arguments for that shell. Empty inherits the login-shell default.
    var arguments: [String] = []
    /// An absolute path. `nil` inherits the usual rule — the directory the
    /// pane was split from, or home.
    var directory: String?
    /// Variables added to the child's environment, on top of the sanitised
    /// inherited one (`SECURITY.md` §4.3). A preset can add and override; it
    /// cannot remove, because a preset is a convenience and unsetting
    /// `PATH` is not one.
    var environment: [String: String] = [:]

    init(name: String) {
        self.name = name
    }

    /// Whether the preset says anything at all. A name with no settings is a
    /// typo, and offering it in a menu would be offering "open a terminal
    /// exactly like the default one".
    var isEmpty: Bool {
        shell == nil && directory == nil && arguments.isEmpty && environment.isEmpty
    }

    /// A shell path has to be absolute — the same rule `Spawn` enforces —
    /// and a directory has to be absolute for the same reason: a relative
    /// one would resolve against whatever Corta was launched from, which on
    /// a Finder launch is `/`.
    var isUsable: Bool {
        guard !isEmpty else { return false }
        if let shell, !shell.hasPrefix("/") { return false }
        if let directory, !directory.hasPrefix("/") { return false }
        return true
    }

    /// Applies one `preset.<name>.<field>` key. Returns whether it was
    /// recognised, so an unrecognised one is preserved as an unknown key
    /// rather than dropped.
    mutating func apply(field: String, value: String) -> Bool {
        if field.hasPrefix("env.") {
            let variable = String(field.dropFirst("env.".count))
            // A name with `=` or NUL in it cannot be put in an environment
            // at all; refusing it here is clearer than letting `execve`
            // decide.
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
            // Space separated, which is all a shell invocation needs here;
            // anything requiring quoting belongs in a script the preset
            // points at.
            arguments = value.split(separator: " ").map(String.init)
        default:
            return false
        }
        return true
    }

    /// The config-file lines that reproduce this preset.
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
