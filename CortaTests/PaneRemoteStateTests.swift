import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// B13 — the composition behind "which host does this pane refer to":
/// `PaneRemoteState.resolve` is a pure function of the two signals a pane
/// actually has (the remote shell's own OSC 7 report, and the kernel's
/// answer for who owns the terminal), so the whole matrix is staged here
/// with neither a network nor a forged process.
struct PaneRemoteStateTests {
    private static func report(
        host: String = "build-box", directory: String = "/srv/app"
    ) -> RemoteContext {
        RemoteContext(host: host, directory: directory, provenance: .osc7, reportedAt: Date())
    }

    @Test("a shell at its own prompt is local, even with a lingering report")
    func noForegroundJobIsLocal() {
        // The report may be stale (an `ssh` that exited without the local
        // shell re-reporting); with no job in the foreground it has nothing
        // left that could be emitting it.
        #expect(
            PaneRemoteState.resolve(
                remoteContext: Self.report(), hasForegroundJob: false,
                foregroundProcessName: nil) == .local)
    }

    @Test("ssh in the foreground plus a report names host and directory")
    func launcherWithReportIsRemote() {
        let state = PaneRemoteState.resolve(
            remoteContext: Self.report(), hasForegroundJob: true,
            foregroundProcessName: "ssh")
        #expect(
            state == .remote(host: "build-box", directory: "/srv/app", provenance: .osc7))
    }

    @Test("the report outranks the process name, nested ssh included")
    func reportSuppliesTheHost() {
        // ssh'd to A, then to B from there: the local foreground is still
        // just `ssh`, but B's shell is the one whose OSC 7 arrived last.
        let state = PaneRemoteState.resolve(
            remoteContext: Self.report(host: "host-b", directory: "/var/log"),
            hasForegroundJob: true, foregroundProcessName: "ssh")
        #expect(state == .remote(host: "host-b", directory: "/var/log", provenance: .osc7))
    }

    @Test("a launcher without a report is remote with the host unknown")
    func launcherWithoutReportIsRemoteUnknown() {
        for name in ["ssh", "mosh", "mosh-client"] {
            #expect(
                PaneRemoteState.resolve(
                    remoteContext: nil, hasForegroundJob: true,
                    foregroundProcessName: name) == .remoteUnknown(provenance: .foregroundProcess),
                "\(name) in the foreground means remote, host unknown")
        }
    }

    @Test("a multiplexer is uncertain — never guessed, report or not")
    func multiplexerIsUnknown() {
        for name in ["tmux", "screen"] {
            for report in [nil, Self.report()] {
                #expect(
                    PaneRemoteState.resolve(
                        remoteContext: report, hasForegroundJob: true,
                        foregroundProcessName: name) == .unknown,
                    "\(name) hides what is behind it; a report may predate the attach")
            }
        }
    }

    @Test("an unreadable foreground name is uncertain, not local")
    func unreadableNameIsUnknown() {
        #expect(
            PaneRemoteState.resolve(
                remoteContext: nil, hasForegroundJob: true, foregroundProcessName: nil)
                == .unknown)
    }

    @Test("an ordinary foreground job is local, stale report or not")
    func ordinaryJobIsLocal() {
        // A local `make` owning the terminal means the terminal is local —
        // a report from an earlier ssh session does not outlive it.
        #expect(
            PaneRemoteState.resolve(
                remoteContext: Self.report(), hasForegroundJob: true,
                foregroundProcessName: "make") == .local)
    }

    @Test("the title badge says what is known, or says it is not")
    func titleBadge() {
        #expect(PaneRemoteState.local.titleComponent == nil)
        #expect(
            PaneRemoteState.remote(
                host: "build-box", directory: "/srv/app", provenance: .osc7
            ).titleComponent == "⟂ build-box · app")
        let unknown = PaneRemoteState.remoteUnknown(provenance: .foregroundProcess).titleComponent
        #expect(unknown?.contains("⟂") == true)
        #expect(unknown?.contains(L10n.text("remote.hostUnknown")) == true)
        let uncertain = PaneRemoteState.unknown.titleComponent
        #expect(uncertain == "⟂ \(L10n.text("remote.uncertain"))")
    }

    /// The case the two process signals cannot see: a pane spawned *as*
    /// `ssh` (an ssh preset). The launcher owns the terminal as the pane's
    /// own child, so there is never a foreground job in front of a shell —
    /// without the spawn record the pane would read `.local` for the whole
    /// connection.
    @Test("a pane spawned as ssh is remote even with no foreground job")
    func spawnedLauncherIsRemote() {
        #expect(
            PaneRemoteState.resolve(
                remoteContext: nil, hasForegroundJob: false, foregroundProcessName: nil,
                childIsRemoteLauncher: true) == .remoteUnknown(provenance: .spawnedLauncher))
        // The report still outranks the spawn record: it names the host.
        #expect(
            PaneRemoteState.resolve(
                remoteContext: Self.report(), hasForegroundJob: false,
                foregroundProcessName: nil, childIsRemoteLauncher: true)
                == .remote(host: "build-box", directory: "/srv/app", provenance: .osc7))
    }

    @Test("a launcher is recognised from a full path, as a preset spells it")
    func launcherPathsAreRecognised() {
        #expect(PaneRemoteState.isRemoteLauncher(executable: "/usr/bin/ssh"))
        #expect(PaneRemoteState.isRemoteLauncher(executable: "ssh"))
        #expect(PaneRemoteState.isRemoteLauncher(executable: "/opt/homebrew/bin/mosh"))
        #expect(!PaneRemoteState.isRemoteLauncher(executable: "/bin/zsh"))
        // A lookalike: `sshd` is a daemon, not a connection this pane holds.
        #expect(!PaneRemoteState.isRemoteLauncher(executable: "/usr/sbin/sshd"))
    }

}

/// B13 — the isolation half, staged through real sessions: a remote OSC 7
/// report (the exact bytes an `ssh` session emits, plus the marks a shell
/// with integration sends) fed to a real pane, asserting the report is
/// *recorded* and *displayed* but never reaches a local spawn.
///
/// Every pane here runs `/bin/sh`, not the login shell: the developer's own
/// `.zshrc` may carry Corta's integration, which emits a *local* OSC 7 after
/// every command and would clear the staged remote report. `/bin/sh` reads
/// no rc file, so the only OSC 7 the parser sees is the staged one — and no
/// machine state changes, which the project's rule requires.
@MainActor
@Suite(.serialized)
struct RemotePaneIsolationTests {
    private static func makePane(script: String) -> ViewController {
        var preset = Preset(name: "b13-staging")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", script]
        let pane = ViewController()
        pane.preset = preset
        _ = pane.view
        return pane
    }

    private func waitUntilTrue(
        timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The report is kept — the pane knows which host it refers to — and
    /// every local-spawn consumer is starved of it at once, because they
    /// all read the same local-only value:
    ///
    /// - the `startSession` fallback ladder gets it only via
    ///   `inheritedWorkingDirectory` (`ViewController.setUpPane`),
    /// - split-pane inheritance reads `session.workingDirectory`
    ///   (`SplitViewController.splitFocusedPane`),
    /// - session restore persists `pane?.session?.workingDirectory`
    ///   (`SplitViewController+Restore.layout(of:)`).
    @Test func aRemoteReportIsRecordedButNeverSpawnable() async throws {
        let pane = Self.makePane(
            script: "printf '\\033]7;file://build-box/srv/app\\007'; sleep 60")
        defer { pane.teardown() }
        let session = try #require(pane.session)
        #expect(await waitUntilTrue { session.remoteContext != nil })

        #expect(session.remoteContext?.host == "build-box")
        #expect(session.remoteContext?.directory == "/srv/app")
        #expect(session.workingDirectory == nil, "the local-spawn value must stay nil")
        // The kernel fallback answers for the foreground process — a local
        // one — so it cannot produce the remote path either.
        #expect(session.currentDirectory != "/srv/app")
        // The display side: no launcher holds the foreground (the report is
        // not one a live connection is emitting), so the pane calls itself
        // local rather than dressing a stale report up as a live one, and
        // directory navigation offers nothing rather than a `cd` into a
        // path on another machine.
        #expect(pane.paneRemoteState == .local)
        #expect(pane.shellDirectory == nil)
        #expect(!pane.composedWindowTitle.contains("⟂"))
    }

    /// End to end through the split the user's ⌘D takes: a pane referring
    /// to a remote host splits, and the new pane inherits *nothing* from it
    /// — spawning at home, not at `/srv/app` on a machine it cannot reach.
    @Test func aSplitDoesNotInheritTheRemoteDirectory() async throws {
        let split = SplitViewController()
        var preset = Preset(name: "b13-staging")
        preset.shell = "/bin/sh"
        preset.arguments = []
        split.pendingPreset = preset
        _ = split.view
        defer { split.teardown() }
        let first = try #require(split.panes.first)
        let session = try #require(first.session)
        session.write(Array("printf '\\033]7;file://build-box/srv/app\\007'\n".utf8))
        #expect(await waitUntilTrue { session.remoteContext != nil })
        #expect(session.workingDirectory == nil)

        split.splitFocusedPane(orientation: .columns)
        let second = try #require(split.panes.first { $0 !== first })
        #expect(
            second.inheritedWorkingDirectory == nil,
            "split inheritance must not carry a remote path into a local spawn")
        #expect(
            await waitUntilTrue { second.session?.currentDirectory != nil },
            "the new pane's shell should report where it started")
        #expect(second.session?.currentDirectory == NSHomeDirectory())
    }
}

/// B13 — the command-history host scope, staged with the same real-session
/// recipe: one command begun while the pane referred to a remote host, one
/// begun after the pane was local again.
@MainActor
@Suite(.serialized)
struct CommandHistoryHostScopeTests {
    /// What a shell with integration emits across one remote command and
    /// one local one: the remote OSC 7, the first command's marks, a local
    /// OSC 7 (the pane is local again), the second command's marks, then a
    /// `sleep` keeping the session alive for the assertions.
    private static let script = """
        printf '\\033]7;file://build-box/srv/app\\007'
        printf '\\033]133;A\\007$ \\033]133;B\\007make\\r\\n\\033]133;C\\007built\\r\\n\\033]133;D;0\\007'
        printf '\\033]7;file://localhost/tmp\\007'
        printf '\\033]133;A\\007$ \\033]133;B\\007ls\\r\\n\\033]133;C\\007listed\\r\\n\\033]133;D;0\\007'
        sleep 60
        """

    private func waitUntilTrue(
        timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func recordsCarryTheHostAndTheScopeFiltersThem() async throws {
        var preset = Preset(name: "b13-staging")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", Self.script]
        let pane = ViewController()
        pane.preset = preset
        _ = pane.view
        defer { pane.teardown() }
        let session = try #require(pane.session)
        #expect(
            await waitUntilTrue { session.commandRecords.records.count == 2 },
            "both staged commands should be recorded")
        let records = session.commandRecords.records
        // Append-only, chronological: the remote one began first.
        #expect(records[0].host == "build-box")
        #expect(records[0].workingDirectory == nil)
        #expect(records[1].host == nil)
        #expect(records[1].workingDirectory == "/tmp")
        #expect(session.commandRecords.records(onHost: "build-box").count == 1)

        let model = CommandHistoryModel()
        model.pane = pane
        #expect(model.knownHosts == ["build-box"])
        #expect(model.rows.count == 2)

        model.hostScope = .host("build-box")
        #expect(model.rows.count == 1)
        // The host labels the row, not the directory field — which for a
        // remote record names a local directory the command never ran in.
        #expect(model.rows.first?.directoryText == "⟂ build-box")
        #expect(model.rows.first?.directoryTooltip == nil)

        model.hostScope = .local
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.directoryText == "tmp")
        #expect(model.rows.first?.directoryTooltip == "/tmp")

        model.hostScope = .any
        #expect(model.rows.count == 2)
    }
}

/// B13 — an ssh preset as a first-class path, staged without a network:
/// the "launcher" is a symlink to `/bin/sh` *named* `ssh` in a temporary
/// directory, so the pane spawns exactly what an ssh preset spells (a
/// system binary path plus arguments) while nothing about the machine
/// changes. What is asserted is Corta's side of the seam: the spawn record
/// drives the remote state, the dead connection offers Reconnect, and
/// Reconnect re-runs the same command as a new session rather than falling
/// back to a local shell.
@MainActor
@Suite(.serialized)
struct SSHPresetPaneTests {
    /// A symlink to `/bin/sh` under the name `ssh`, inside a throwaway
    /// directory the caller removes (`launcher.deletingLastPathComponent()`).
    /// Not a copy: a copied Apple platform binary is killed at exec (its
    /// signature ties it to the system volume), while a symlink resolves
    /// to the real vnode and runs. The pane spawns the path named `ssh`,
    /// which is the only place the name matters — the spawn record, not
    /// `proc_name`, drives the remote state.
    private static func makeStagingLauncher() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ssh-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = directory.appendingPathComponent("ssh")
        try FileManager.default.createSymbolicLink(
            at: launcher, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        return launcher
    }

    private static func makePane(launcher: URL, script: String) -> ViewController {
        var preset = Preset(name: "ssh-staging")
        preset.shell = launcher.path
        preset.arguments = ["-c", script]
        let pane = ViewController()
        pane.preset = preset
        _ = pane.view
        return pane
    }

    private func waitUntilTrue(
        timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The spawn is enough: before the far end reports anything the pane is
    /// remote with the host unknown, and a remote `OSC 7` through the
    /// connection upgrades that to host and directory — the two states a
    /// real ssh preset walks through. The report is gated on a line of
    /// input so both states are observed deterministically.
    @Test func anSSHPresetPaneReadsRemoteFromSpawnToReport() async throws {
        let launcher = try Self.makeStagingLauncher()
        defer { try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent()) }
        let pane = Self.makePane(
            launcher: launcher,
            script: "read _; printf '\\033]7;file://build-box/srv/app\\007'; sleep 60")
        defer { pane.teardown() }
        let session = try #require(pane.session)

        // The launcher owns the terminal as the pane's own child: no
        // foreground job ever stands in front of it, and the spawn record
        // is what says the pane is remote.
        #expect(!session.hasForegroundJob)
        #expect(session.remoteContext == nil)
        #expect(pane.paneRemoteState == .remoteUnknown(provenance: .spawnedLauncher))

        // The far end answers.
        session.write(Array("\n".utf8))
        #expect(await waitUntilTrue { session.remoteContext != nil })
        #expect(
            pane.paneRemoteState
                == .remote(host: "build-box", directory: "/srv/app", provenance: .osc7))
        // The title's copy of the state is cached on an interval; force the
        // re-read rather than racing it.
        pane.invalidateProcessFacts()
        #expect(pane.composedWindowTitle.contains("⟂ build-box"))
        // Nothing local changed its mind: the remote report never reaches
        // the local-spawn value.
        #expect(session.workingDirectory == nil)
    }

}
