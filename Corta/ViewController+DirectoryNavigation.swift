import Cocoa
import CortaTerminal

/// B08 — changing directory through shell integration, and the safety gate
/// that keeps an app-initiated `cd` from landing somewhere the user did not
/// ask for.
extension ViewController {
    /// Whether this pane can safely receive an app-initiated directory
    /// change right now — the four checks the issue's acceptance criteria
    /// name, in one place, so nothing that changes a directory has to
    /// re-derive them:
    ///
    /// - **Pane identity**: the pane still exists and has a live session
    ///   (`isOperable`) — a closed pane has nothing to write to.
    /// - **Remote context**: implicit rather than checked here.
    ///   `session.currentDirectory` only ever names a *local* path —
    ///   `Performer+OSC.swift`'s `setWorkingDirectory` already drops an
    ///   `OSC 7` report naming a remote host, and the kernel-side fallback
    ///   (`PTY.currentWorkingDirectory`) cannot report one either — so
    ///   nothing reachable from here can offer a directory whose `cd` would
    ///   go to a host that never heard of it. (B13, not yet built, is where
    ///   an SSH pane's *own* remote directories will need this revisited.)
    /// - **Prompt state**: `hasShellIntegration` (no marks means no way to
    ///   know whether a command is running or a TUI holds the screen) and
    ///   `!isCommandRunning` — a busy shell, including a TUI (which never
    ///   emits `OSC 133 ; D` while it has the terminal) must not receive
    ///   input meant for a shell prompt.
    /// - **Existing input**: `promptEndPosition` must still be exactly
    ///   where the cursor is. If the user has typed anything since the
    ///   prompt finished drawing, the cursor has moved past it, and a `cd`
    ///   landing there would run alongside — or inside — whatever they were
    ///   typing.
    var canChangeDirectorySafely: Bool {
        guard isOperable, session.hasShellIntegration, !session.isCommandRunning else {
            return false
        }
        guard let end = session.promptEndPosition else { return false }
        let grid = session.snapshot()
        guard let screenRow = grid.screenRow(ofAbsoluteRow: end.row) else { return false }
        return grid.cursor.row == screenRow && grid.cursor.column == end.column
    }

    /// Writes `cd '<path>'` followed by Return, only when
    /// `canChangeDirectorySafely` holds — returns whether it did. Single-
    /// quoted, with any embedded `'` escaped as `'\''`, rather than passed
    /// unquoted: `path` is app-constructed, from `OSC 7` by way of
    /// `DirectoryHistory`, never stream-supplied text a child sent
    /// (`SECURITY.md` §6's rule is about the latter), but the quoting still
    /// has to survive a directory a user could genuinely have — a space, an
    /// apostrophe, an emoji — without breaking out of the argument.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely else { return false }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        session.write(Array("cd '\(escaped)'\r".utf8))
        return true
    }
}
