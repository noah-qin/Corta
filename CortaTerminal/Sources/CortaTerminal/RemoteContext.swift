import Foundation

/// B13 — a directory on *another* machine this pane's shell has reported,
/// kept next to — and never inside — the local-spawn state.
///
/// A shell reached over `ssh` announces its working directory the same way a
/// local shell does (`OSC 7`, `file://host/path`), except the path names a
/// file on a different computer. Before B13 the parser dropped those reports
/// outright, which kept every local-spawn path safe but left the app unable
/// to say *which* host a pane was actually talking to. Recording the report
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
    /// Where the report came from. Today every report is `OSC 7`; the app
    /// layer will add `.foregroundProcess` when it learns to recognise an
    /// `ssh` (or `mosh`, …) process in the foreground and infer the host
    /// from its arguments rather than from a sequence the remote shell
    /// chose to send.
    public enum Provenance: Sendable, Equatable {
        /// The remote shell emitted `OSC 7 ; file://host/path` itself.
        case osc7
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
