// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CortaTerminal
import Testing
@testable import Corta

/// An ssh preset as a first-class path, staged without a network:
/// the "launcher" is a symlink to `/bin/sh` *named* `ssh` in a temporary
/// directory, so the pane spawns exactly what an ssh preset spells (a
/// system binary path plus arguments) while nothing about the machine
/// changes. What is asserted is Corta's side of the seam: the spawn record
/// drives the remote state, the dead connection offers Reconnect, and
/// Reconnect re-runs the same command as a new session rather than falling
/// back to a local shell.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
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
        let deadline = SuspendingClock.now + timeout * testTimeoutScale
        while SuspendingClock.now < deadline {
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
        #expect(pane.remote.state == .remoteUnknown(provenance: .spawnedLauncher))

        // The far end answers.
        session.write(Array("\n".utf8))
        #expect(await waitUntilTrue { session.remoteContext != nil })
        #expect(
            pane.remote.state
                == .remote(host: "build-box", directory: "/srv/app", provenance: .osc7))
        // The title's copy of the state is cached on an interval; force the
        // re-read rather than racing it.
        pane.windowTitle.invalidateProcessFacts()
        #expect(pane.windowTitle.composed.contains(PaneRemoteState.badge("build-box")))
        // Nothing local changed its mind: the remote report never reaches
        // the local-spawn value.
        #expect(session.workingDirectory == nil)
    }

    /// The badge is child-supplied text like every other title component:
    /// a percent-encoded newline in the OSC 7 path decodes to a real one,
    /// and must be stripped before it reaches the title bar.
    @Test func theBadgeIsSanitisedLikeEveryOtherTitleComponent() async throws {
        let launcher = try Self.makeStagingLauncher()
        defer { try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent()) }
        let pane = Self.makePane(
            launcher: launcher,
            script: "printf '\\033]7;file://build-box/srv/app%%0Ainjected\\007'; sleep 60")
        defer { pane.teardown() }
        let session = try #require(pane.session)
        #expect(await waitUntilTrue { session.remoteContext != nil })
        #expect(session.remoteContext?.directory == "/srv/app\ninjected")
        pane.windowTitle.invalidateProcessFacts()
        let title = pane.windowTitle.composed
        #expect(title.contains(PaneRemoteState.badge("build-box")))
        #expect(!title.contains("\n"))
    }

    /// The dead-connection seam: the launcher exits, the pane goes local
    /// again (a stale report must not dress it up), and Reconnect is what
    /// is offered — a new session running the same command, whose remote
    /// context starts empty until the new connection reports. The launcher
    /// blocks on `read` so each liveness phase is observed while it lasts.
    @Test func aDeadLauncherOffersReconnectAsANewConnection() async throws {
        let launcher = try Self.makeStagingLauncher()
        defer { try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent()) }
        let pane = Self.makePane(launcher: launcher, script: "read _")
        defer { pane.teardown() }
        let dead = try #require(pane.session)
        #expect(await waitUntilTrue { pane.remote.state == .remoteUnknown(provenance: .spawnedLauncher) })
        #expect(!pane.remote.canReconnect, "a live connection has nothing to reconnect")

        dead.write(Array("\n".utf8))
        #expect(await waitUntilTrue { dead.pty.exitStatus != nil })
        #expect(pane.remote.state == .local, "the exited launcher owns nothing any more")
        #expect(pane.remote.canReconnect)

        pane.remote.reconnectRemote(nil)
        let respawned = try #require(pane.session)
        #expect(respawned !== dead)
        // The same command, byte for byte — not a paraphrase of it.
        #expect(pane.launchedCommand?.executable == launcher.path)
        #expect(pane.launchedCommand?.arguments == ["-c", "read _"])
        // A fresh session carries nothing from the dead one: no host, no
        // directory, and the badge is back to what the spawn alone can say.
        #expect(respawned.remoteContext == nil)
        #expect(
            await waitUntilTrue {
                pane.remote.state == .remoteUnknown(provenance: .spawnedLauncher)
            })
    }

    /// The honesty half: when the recorded command can no longer run, a
    /// reconnect fails as itself — the fallback ladder would land the pane
    /// in a local `/bin/zsh` while the user asked for the host back, which
    /// is the one substitution Reconnect must never make silently.
    @Test func aReconnectThatCannotRunFailsRatherThanFallingBack() async throws {
        let launcher = try Self.makeStagingLauncher()
        let pane = Self.makePane(launcher: launcher, script: "exit 0")
        defer {
            pane.teardown()
            try? FileManager.default.removeItem(at: launcher.deletingLastPathComponent())
        }
        #expect(await waitUntilTrue { pane.session?.pty.exitStatus != nil })
        #expect(pane.remote.canReconnect)

        // The binary is gone now: the exact command cannot be re-run.
        try FileManager.default.removeItem(at: launcher)
        pane.remote.reconnectRemote(nil)
        #expect(
            await waitUntilTrue { pane.failureView != nil },
            "a failed reconnect shows the failure view instead of a silent local shell")
        #expect(pane.remote.canReconnect, "the button stays on offer — the command is still remote")
    }

    /// The negative: a local shell never sees Reconnect, dead or alive —
    /// Try Again already covers it, and two names for one respawn is how a
    /// menu teaches a distinction that does not exist.
    @Test func aLocalShellNeverOffersReconnect() async throws {
        var preset = Preset(name: "local-staging")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "exit 0"]
        let pane = ViewController()
        pane.preset = preset
        _ = pane.view
        defer { pane.teardown() }
        #expect(await waitUntilTrue { pane.session?.pty.exitStatus != nil })
        #expect(!pane.remote.canReconnect)
    }
}
