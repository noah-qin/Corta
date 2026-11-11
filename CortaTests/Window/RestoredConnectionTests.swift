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
import Foundation
import Testing

@testable import Corta

/// A pane that was on SSH when Corta quit (`#519`): the saved arrangement's
/// remote side decides whether a launch shows the ended-session panel, notes a
/// hand-typed launcher, or spawns as before. The decision is pure; the pane
/// tests need Metal 4, as every real pane does.
@MainActor
struct RestoredConnectionTests {
    private typealias RestoreAction = RestoredRemoteAction

    private static let key = "user@build-box:2222 -i /Users/example/.ssh/id_build"

    private static func target() throws -> SSHTarget {
        try #require(SSHTarget(key: key))
    }

    private static func windowState(remote: PaneRemoteRestore) -> WindowState {
        WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .pane(directory: "/tmp", remote: remote))
    }

    // MARK: - A restored remote side (#519)

    @Test("a connect-sheet target round-trips in the pane that had it")
    func remoteTargetRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let store = SessionRestore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try #require(SSHTarget(key: "user@build-box:2222 -i /Users/example/.ssh/id_build"))
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .split(
                vertical: true, position: 0.5,
                first: .pane(directory: "/tmp", remote: .target(target.key)),
                second: .pane(directory: nil, remote: .launcher)))
        store.save([state])
        #expect(store.load() == [state])
        // On disk as the connect sheet's own form — what Recent Hosts keeps —
        // never as a host picked out of terminal output.
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(raw.contains("id_build"), "the target is saved as the sheet made it")
        #expect(raw.contains("\"launcher\":true"))
    }

    @Test("state written by 1.6.2 still restores, with no remote side")
    func stateBeforeRemoteSidesStillRestores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-restore-\(UUID().uuidString)")
        let store = SessionRestore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = Data(
            #"""
            [{"version": 1, "frame": {"x": 0, "y": 0, "width": 900, "height": 560},
              "layout": {"pane": {"directory": null, "presetName": "work", "isFocused": true}},
              "isSelectedTab": true}]
            """#.utf8)
        try json.write(to: store.fileURL)
        let states = store.load()
        #expect(states.count == 1, "a 1.6.2 arrangement is not skipped")
        #expect(states.first?.layout.firstPresetName == "work")
        #expect(states.first?.layout.firstRemote == nil)
    }

    @Test("a saved target this build cannot read keeps the fact of a remote pane")
    func unreadableTargetDegradesToTheLauncher() throws {
        let json = Data(#"{"pane": {"directory": "/tmp", "remote": {"target": "not a host!"}}}"#.utf8)
        let layout = try JSONDecoder().decode(PaneLayout.self, from: json)
        // The note is right; a destination ssh could not be given is not kept.
        #expect(layout == .pane(directory: "/tmp", remote: .launcher))
    }

    @Test("the remote side bumps the saved format version, so older builds skip it")
    func remoteSideBumpsTheFormatVersion() {
        // A build that does not know a saved target would restore the pane as
        // a silent local shell, so the version makes it skip the arrangement
        // instead (#519). 1.6.2 wrote version 1.
        #expect(WindowState.currentVersion >= 2)
    }

    @Test("repair keeps a pane's saved remote side")
    func repairKeepsRemoteSide() {
        let layout = PaneLayout.pane(
            directory: "/no/such/directory", presetName: "build", remote: .target("build-box"))
        #expect(
            layout.droppingMissingDirectories()
                == .pane(directory: nil, presetName: "build", remote: .target("build-box")))
        #expect(layout.validated() == layout)
        #expect(layout.firstRemote == .target("build-box"))
    }

    @Test("a saved connect-sheet target shows the panel; a launcher gets a note")
    func restoreDecision() throws {
        let target = try Self.target()
        #expect(RestoreAction.forRestore(nil, strictRespawn: false) == .spawn)
        #expect(
            RestoreAction.forRestore(.target(Self.key), strictRespawn: false)
                == .connectionPanel(target))
        #expect(RestoreAction.forRestore(.launcher, strictRespawn: false) == .spawnWithRemoteNote)
        // Reconnect reuses the saved command; it is never the panel again.
        #expect(RestoreAction.forRestore(.target(Self.key), strictRespawn: true) == .spawn)
        // A target this build cannot read still does not become a silent
        // local shell: the fact that the pane was remote is kept.
        #expect(
            RestoreAction.forRestore(.target("not a host!"), strictRespawn: false)
                == .spawnWithRemoteNote)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func restoredConnectionPaneNamesTheHostAndRunsNothing() throws {
        let target = try Self.target()
        let split = SplitViewController(
            setup: SplitViewController.Setup(restore: Self.windowState(remote: .target(target.key))))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Closing a programmatic window that releases itself over-releases it.
        window.isReleasedWhenClosed = false
        defer {
            split.teardown()
            window.close()
        }
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()

        let pane = try #require(split.focusedPane)
        // A launch may not connect by itself, nor stand a local shell in for
        // the remote session.
        #expect(pane.session == nil)
        #expect(pane.launchedCommand == nil, "no ssh process was started")
        let overlay = try #require(pane.sessionEndedPanel)
        let titles = overlay.panel.buttons.map(\.title)
        #expect(overlay.panel.content.title.contains(target.displayName), "the panel names the host")
        #expect(titles.contains(L10n.text("failure.button.reconnect")))
        #expect(titles.contains(L10n.text("session.ended.newSession")))
        // Reconnect would run the connect sheet's own preset: /usr/bin/ssh
        // with the target's argv, as if the sheet had connected it.
        let reconnect = try #require(pane.remote.reconnectCommand)
        #expect(reconnect.executable == "/usr/bin/ssh")
        #expect(reconnect.arguments == target.sshArguments)
        #expect(pane.preset?.connectTarget == target)

        // New Session is a local shell in the saved directory, not another
        // connection: the saved ssh preset is dropped.
        pane.startLocalSession()
        #expect(pane.sessionEndedPanel == nil)
        #expect(pane.preset == nil)
        #expect(pane.session != nil, "a local shell starts")
        #expect(pane.remote.connectionHost == nil, "no ssh command remains")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func restoredConnectionInASplitComesBackAsAPanel() throws {
        let target = try Self.target()
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 0, y: 0, width: 900, height: 560)),
            layout: .split(
                vertical: true, position: 0.5,
                first: .pane(directory: "/tmp"),
                second: .pane(directory: "/tmp", remote: .target(target.key))))
        let split = SplitViewController(
            setup: SplitViewController.Setup(restore: state, directoriesChecked: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            split.teardown()
            window.close()
        }
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        // What `viewWillAppear` does once the window shows.
        split.applyPendingRestore()
        split.view.layoutSubtreeIfNeeded()

        #expect(split.panes.count == 2, "the split comes back")
        // The local pane spawns its shell; the saved connection does not.
        #expect(split.panes.contains { $0.session != nil })
        let restored = try #require(split.panes.first { $0.sessionEndedPanel != nil })
        #expect(restored.session == nil)
        #expect(restored.launchedCommand == nil, "no ssh process was started")
        let title = try #require(restored.sessionEndedPanel).panel.content.title
        #expect(title.contains(target.displayName))
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func handTypedRemotePaneRestoresAsALocalShellWithANote() throws {
        let pane = TerminalPaneViewController()
        // What the capture side records for a pane running a hand-typed ssh.
        pane.restoredRemote = .launcher
        _ = pane.view
        defer { pane.teardown() }

        #expect(pane.sessionEndedPanel == nil)
        #expect(pane.session != nil, "a local shell is restored")
        #expect(pane.preset == nil)
        #expect(pane.pendingSessionNotice == L10n.text("restore.remoteNotResumed"))
    }
}
