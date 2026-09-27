import Foundation

/// A directory on *another* machine this pane's shell has reported,
/// kept next to — and never inside — the local-spawn state.
///
/// A shell reached over `ssh` announces its working directory the same way a
/// local shell does (`OSC 7`, `file://host/path`), except the path names a
/// file on a different computer. Dropping those reports outright would keep
/// every local-spawn path safe but leave the app unable to say *which* host
/// a pane is actually talking to. Recording the report
/// here — isolated from `Terminal.workingDirectory`, which stays
/// local-only — gives the app something to display without giving it
/// anything it could `chdir` into.
///
/// **Informational only.** Nothing that spawns a local process — new tabs,
/// split panes, session restore, file-reference resolution — may ever read
/// this. Those consumers keep reading `Terminal.workingDirectory` /
/// `TerminalSession.workingDirectory`, which are local-or-nil by
/// construction, and a remote report never changes that.
public struct RemoteContext: Sendable, Equatable {
    /// Where the report came from. `OSC 7` is the remote shell's own
    /// statement and the only one that can name a host; `.foregroundProcess`
    /// is the app layer recognising a remote launcher (`ssh`, `mosh`, …) in
    /// the foreground — lower confidence, and it arrives with no host at
    /// all, because a process name carries none and the launcher's argv is
    /// deliberately not parsed for one (an alias, a `~/.ssh/config` name or
    /// a jump-host chain would all read back wrong).
    public enum Provenance: Sendable, Equatable {
        /// The remote shell emitted `OSC 7 ; file://host/path` itself.
        case osc7
        /// The app saw a remote launcher holding the pane's foreground
        /// (`PTY.foregroundProcessName`), not a sequence the remote shell
        /// chose to send.
        case foregroundProcess
        /// The app spawned the remote launcher itself, as the pane's own
        /// child (an ssh preset). No `proc_name` is involved — the launcher
        /// owns the terminal *as* the child, so the foreground-group check
        /// never fires — and the answer is certain rather than recognised:
        /// the app knows what it exec'd.
        case spawnedLauncher
    }

    /// The host the report names, normalised the way `Performer.normalize
    /// Hostname` normalises everything else: lowercased, trailing dot
    /// stripped. Not resolved and not validated against any known-host list
    /// — it is the name the remote shell chose to send, shown to the user
    /// as such.
    public let host: String

    /// The path on that host, percent-decoded. A path on *that* machine:
    /// a same-named path on this one is a different file.
    public let directory: String

    public let provenance: Provenance

    /// When this report arrived. Two panes can hold the same host and
    /// directory by coincidence; the timestamp is what lets the app order
    /// or age a display of them.
    public let reportedAt: Date

    public init(host: String, directory: String, provenance: Provenance, reportedAt: Date) {
        self.host = host
        self.directory = directory
        self.provenance = provenance
        self.reportedAt = reportedAt
    }
}
