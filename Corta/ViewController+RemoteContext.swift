import Cocoa
import CortaTerminal

/// B13 — which host and directory a pane refers to, as a question asked of
/// the pane. The composition itself is a pure value (`PaneRemoteState`);
/// this extension is the pane's fresh read of it, and the home of the one
/// action that knowledge enables: an honest reconnect.
extension ViewController {
    /// This pane's remote state, resolved now.
    ///
    /// Two readers, two cadences. The title reads the *cached* copy
    /// (`refreshProcessFactsIfStale`, an interval — syscalls have no place
    /// on a per-output-batch path). One-off questions — menu validation,
    /// tests — read this, which pays the `tcgetpgrp`/`proc_name` syscalls
    /// each time and so never answers from a quarter-second-old fact.
    var paneRemoteState: PaneRemoteState {
        guard isOperable else { return .local }
        return resolveRemoteState()
    }

    /// Whether the pane's own child is a live remote launcher — the case
    /// the foreground-process signal cannot see, because the launcher owns
    /// the terminal *as* the pane's child and no job ever stands in front
    /// of it. What the pane exec'd (`launchedCommand`) is the certain
    /// version of what `proc_name` can only recognise.
    ///
    /// `exitStatus` is the liveness check rather than the failure view's
    /// state: an `ssh` that exited in a pane still showing its last output
    /// is dead, and a recorded report from it is stale.
    var childIsLiveRemoteLauncher: Bool {
        guard let launchedCommand,
            PaneRemoteState.isRemoteLauncher(executable: launchedCommand.executable)
        else { return false }
        return session != nil && session.pty.exitStatus == nil
    }

    // MARK: - Reconnect (B13)

    /// The exact command a reconnect re-runs: what actually spawned — or,
    /// when the spawn never succeeded at all, the preset's own command,
    /// which is what the failed pane was reaching for.
    var reconnectCommand: (executable: String, arguments: [String])? {
        if let launchedCommand { return launchedCommand }
        guard let shell = preset?.shell else { return nil }
        return (shell, preset?.arguments ?? [])
    }

    /// Reconnect is offered only where it means something: the pane's
    /// session *was* a remote launcher (or was trying to be) and that child
    /// is gone. A local shell already has Try Again (the failure view) and
    /// needs nothing here; a live `ssh` has nothing to reconnect — the
    /// command would have to kill the working connection to make a second
    /// one.
    ///
    /// **Connection sharing, evaluated and declined** (issue #40):
    /// `ControlMaster`/`ControlPersist` would buy authenticate-once and a
    /// reconnect that skips the handshake, at the cost of an opaque master
    /// process whose lifetime Corta would own — killed on quit (or leaked),
    /// and silently coupling panes that happen to share a host. None of
    /// that is necessary: Corta spawns the system's `/usr/bin/ssh`, so a
    /// user's own `Control*` settings in `~/.ssh/config` already apply,
    /// master and all, with ssh itself owning the lifetime. The
    /// recommendation stands: respect the user's ssh config, add nothing
    /// Corta-side.
    var canReconnectRemote: Bool {
        guard let command = reconnectCommand,
            PaneRemoteState.isRemoteLauncher(executable: command.executable)
        else { return false }
        return session == nil || session.pty.exitStatus != nil
    }

    /// Whether the pane's command line asks the far end to reattach to an
    /// existing multiplexer session (`tmux attach`, `screen -r`…). Only a
    /// copy decision: the reattach, when it happens, is the user's own
    /// command doing it, so the wording may say so — what it must never do
    /// is let Corta claim the dead shell's state was restored.
    nonisolated static func reattachesRemoteSession(_ arguments: [String]) -> Bool {
        // Words, not arguments: `ssh host tmux attach` and
        // `ssh host "tmux attach"` are the same remote command line.
        let words = arguments.flatMap { $0.split(separator: " ").map(String.init) }
        for (index, word) in words.enumerated() {
            let rest = words[(index + 1)...]
            switch word {
            case "tmux":
                // The first non-flag word is the subcommand.
                if let verb = rest.first(where: { !$0.hasPrefix("-") }),
                    ["attach", "attach-session", "a"].contains(verb)
                { return true }
            case "screen":
                // `-r`, `-x` and their combinations (`-rr`, `-xR`) all
                // reattach rather than start a fresh session.
                if rest.contains(where: { $0.hasPrefix("-r") || $0.hasPrefix("-x") }) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// Shell ▸ Reconnect, and the failure view's button of the same name.
    @objc func reconnectRemote(_ sender: Any?) {
        guard canReconnectRemote else { return }
        rebuildPane(strictRespawn: true)
    }

    /// What the pane says once the new connection is running. Never
    /// "restored": the process and the remote shell state are gone, and
    /// the copy says so. When the command itself reattaches (`tmux
    /// attach`), it says *that* instead — the user's command earns the
    /// credit, and the caveat that it attaches to whatever exists now.
    var reconnectNotice: String {
        if let command = reconnectCommand, Self.reattachesRemoteSession(command.arguments) {
            return L10n.text("toast.reconnectedReattach")
        }
        return L10n.text("toast.reconnected")
    }
}
