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
    /// - **Remote context** (B13): the `cd` goes to the pane's own shell,
    ///   so a *remote* directory is safe to send when the pane is remote —
    ///   the shell receiving it runs on the machine the path belongs to.
    ///   What must never happen is a remote path reaching a *local* spawn
    ///   (a split pane, a restored session), and that is structural rather
    ///   than checked here: those readers consume `session.workingDirectory`,
    ///   which `Performer+OSC.swift`'s `setWorkingDirectory` keeps
    ///   local-only, while the remote report lives in `remoteContext`.
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

    /// B13 — the directory this pane's shell is actually sitting in,
    /// whichever machine that shell runs on: the local report/fallback when
    /// the pane is local, the pane's own reported remote directory when it
    /// is remote (with the host attached, so a caller can say whose path it
    /// is). `nil` when neither side knows — a remote launcher that has not
    /// reported yet has no honest answer.
    ///
    /// Only ever fed to `changeDirectory(to:)`. Anything that spawns a
    /// local process or touches Finder keeps reading `session
    /// .workingDirectory`, which is local-or-nil by construction.
    var shellDirectory: (path: String, host: String?)? {
        switch paneRemoteState {
        case .remote(let host, let directory, _):
            return (directory, host)
        case .local:
            return session.workingDirectory.map { ($0, nil) }
        case .remoteUnknown, .unknown:
            // Remote with no report, or a multiplexer that may be attached
            // anywhere: `session.workingDirectory` here is a *stale local*
            // path from before the connection, and sending its `cd` to a
            // shell that may be on another machine is the wrong-direction
            // leak. No honest answer, so no offer.
            return nil
        }
    }

    /// Writes `cd '<path>'` followed by Return, only when
    /// `canChangeDirectorySafely` holds — returns whether it did. Single-
    /// quoted, with any embedded `'` escaped as `'\''`, rather than passed
    /// unquoted: `path` is app-constructed — from `OSC 7` by way of
    /// `DirectoryHistory`, or (B13) from the pane's own remote report —
    /// never stream-supplied text a child sent (`SECURITY.md` §6's rule is
    /// about the latter), but the quoting still has to survive a directory
    /// a user could genuinely have — a space, an apostrophe, an emoji —
    /// without breaking out of the argument. A remote path is safe here for
    /// the reason `shellDirectory` gives: the `cd` is delivered to the
    /// pane's own shell, on the machine that path names.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely else { return false }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        session.write(Array("cd '\(escaped)'\r".utf8))
        return true
    }
}
