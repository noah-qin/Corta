import CortaTerminal
import Foundation

/// B13 — which machine a pane's terminal is actually talking to, composed
/// from the two independent signals that can answer it, kept as a plain
/// value so the composition is testable without a pane, a pty or a window.
///
/// - The remote shell's own `OSC 7` report (`TerminalSession.remoteContext`)
///   is the high-confidence signal and the only one that names a host.
/// - The foreground process (`PTY.foregroundProcessName`) is the kernel's
///   answer: an `ssh`/`mosh` holding the terminal means the pane is remote
///   even when the far end reports nothing; a `tmux`/`screen` means the
///   pane *may* be — it could be attached to a session on another machine —
///   so the state is uncertain and says so rather than guessing.
///
/// Two things are deliberately never done: reading the host out of the
/// terminal's text (a prompt that merely *looks* like `user@host` is child
/// output, hostile and unparseable — `SECURITY.md` §2), and parsing the
/// launcher's argv for one (aliases, `~/.ssh/config` names and jump-host
/// chains would all read back wrong).
nonisolated enum PaneRemoteState: Equatable {
    /// The pane's own shell — or an ordinary local command — owns the
    /// terminal. A remote report left over from an `ssh` that has since
    /// exited is stale, and a lingering one does not make a local prompt
    /// look remote: with no remote launcher in the foreground the report
    /// has nothing left that could be emitting it.
    case local
    /// A remote launcher holds the foreground and the far end reported
    /// where it is — host and directory are known, with the report's own
    /// provenance attached.
    case remote(host: String, directory: String, provenance: RemoteContext.Provenance)
    /// A remote launcher holds the foreground but the far end has reported
    /// nothing: the pane is remote, the host is not known.
    case remoteUnknown(provenance: RemoteContext.Provenance)
    /// A multiplexer holds the foreground, or the foreground's name could
    /// not be read at all: what is behind it cannot be told from here, and
    /// even a recorded report may predate the attach. Shown as uncertain.
    case unknown

    /// Executable names (as `proc_name` reports them) whose foreground
    /// means the terminal is talking to another machine. `mosh-client` is
    /// the local half of a mosh connection; the far shell is remote either
    /// way.
    private static let remoteLaunchers: Set<String> = ["ssh", "mosh", "mosh-client"]

    /// Executable names that hide what is behind them: the session a local
    /// `tmux`/`screen` is attached to may itself be running over `ssh`, and
    /// neither signal available here can say.
    private static let multiplexers: Set<String> = ["tmux", "screen"]

    /// Composes the two signals into the one state a display consumes.
    /// `hasForegroundJob` and `foregroundProcessName` are read separately
    /// rather than the name alone because the name is `nil` both for "the
    /// shell is at a prompt" (local) and for "the name could not be read"
    /// (uncertain) — two answers a display must not conflate.
    static func resolve(
        remoteContext: RemoteContext?, hasForegroundJob: Bool, foregroundProcessName: String?
    ) -> PaneRemoteState {
        guard hasForegroundJob else { return .local }
        guard let name = foregroundProcessName?.lowercased() else { return .unknown }
        if remoteLaunchers.contains(name) {
            // The report outranks the process: it is the remote shell
            // speaking for itself, and it is the only source of a host.
            if let remoteContext {
                return .remote(
                    host: remoteContext.host, directory: remoteContext.directory,
                    provenance: remoteContext.provenance)
            }
            return .remoteUnknown(provenance: .foregroundProcess)
        }
        if multiplexers.contains(name) { return .unknown }
        return .local
    }

    /// The window-title badge, or `nil` when the pane is plainly local and
    /// the title has nothing to say. A sober marker and what is known —
    /// `⟂ build-box · app` — and an honest word when it is not
    /// (`⟂ host unknown`, `⟂ remote?`), never a guess dressed up as one.
    var titleComponent: String? {
        switch self {
        case .local:
            return nil
        case .remote(let host, let directory, _):
            return "⟂ \(host) · \(Self.abbreviated(directory))"
        case .remoteUnknown:
            return "⟂ \(L10n.text("remote.hostUnknown"))"
        case .unknown:
            return "⟂ \(L10n.text("remote.uncertain"))"
        }
    }

    /// The last path component, like the local-directory part of the title
    /// (`ViewController.abbreviated`) — but without its `~` rule, which is
    /// about *this* machine's home and means nothing on another one.
    private static func abbreviated(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
