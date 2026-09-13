import Cocoa
import CortaTerminal

/// B13 — which host and directory a pane refers to, as a question asked of
/// the pane. The composition itself is a pure value (`PaneRemoteState`);
/// this extension is the pane's fresh read of it.
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
        return PaneRemoteState.resolve(
            remoteContext: session.remoteContext,
            hasForegroundJob: session.hasForegroundJob,
            foregroundProcessName: session.foregroundProcessName,
            childIsRemoteLauncher: childIsLiveRemoteLauncher)
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
}
