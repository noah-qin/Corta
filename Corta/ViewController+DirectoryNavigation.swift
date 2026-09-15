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
    /// `canChangeDirectorySafely` holds — returns whether it did.
    ///
    /// Every `path` here began as an `OSC 7` report — the local shell's by
    /// way of `DirectoryHistory`, or (B13) the pane's own remote report —
    /// which is text a child sent, the thing `SECURITY.md` §6 says never
    /// to write back to a child. It goes back anyway, under three
    /// conditions that together are what make it the user's command
    /// rather than the stream's: it is sent only on the user's own action
    /// (a menu item, a history row) to the shell on the machine the path
    /// names; it is single-quoted with `'` escaped as `'\''`, so a space,
    /// an apostrophe or an emoji stay inside the one argument; and a path
    /// carrying a control character is refused outright — a real directory
    /// may hold a newline, but a `cd` line with one in it is the one shape
    /// a shell other than the ones this quoting was checked against could
    /// read as two commands, and no directory is worth that.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely, Self.isSendableDirectoryPath(path) else { return false }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        session.write(Array("cd '\(escaped)'\r".utf8))
        return true
    }

    /// Whether a directory path may be written into a `cd` line at all:
    /// nothing from the C0/C1 control ranges (a newline, a carriage return,
    /// an escape) and nothing empty.
    nonisolated static func isSendableDirectoryPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            }
    }
}
