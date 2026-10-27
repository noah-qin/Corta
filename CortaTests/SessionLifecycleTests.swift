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
import CortaPOSIX
import Darwin
import Testing

@testable import Corta
@testable import CortaTerminal

/// A child that exits on its own (`exit`, a crash, `kill`) must produce
/// a UI reaction — before this, `onChildExit` was never installed and the
/// pane simply went quiet — and a child that exits *because* the user closed
/// the pane (`teardown()`'s `SIGHUP`) must never mutate a pane that is
/// already gone. `didTeardown` is what tells the two apart: see
/// `ViewController.noteChildExit`.
///
/// `.serialized` and a real shell, for the same reason as `PaneTeardownTests`.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct SessionLifecycleTests {
    private func makePane(preset: Preset? = nil) -> ViewController {
        let pane = ViewController()
        pane.preset = preset
        _ = pane.view
        return pane
    }

    @Test(arguments: [TerminalSession.IOFailure.Operation.read, .write])
    func anIOFailureOffersExplicitRetryAndIgnoresOldCallbacks(
        operation: TerminalSession.IOFailure.Operation
    ) async throws {
        var preset = Preset(name: "runtime-failure")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "exec /bin/cat"]
        let pane = makePane(preset: preset)
        defer { pane.teardown() }
        let old = try #require(pane.session)
        let callback = try #require(old.onIOFailure)
        callback(TerminalSession.IOFailure(operation: operation, message: "injected test fault"))
        #expect(await waitUntilTrue(timeout: .seconds(5)) { pane.failureView != nil })
        #expect(!pane.isOperable)
        #expect(old.pty.waitForExit(timeout: .seconds(0)) == nil)
        let failure = try #require(pane.failureView)
        failure.onRetry?()
        #expect(pane.isOperable)
        #expect(pane.session !== old)
        #expect(await waitUntilTrue(timeout: .seconds(5)) {
            old.pty.waitForExit(timeout: .seconds(0)) != nil
        })
        callback(TerminalSession.IOFailure(operation: operation, message: "stale test fault"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(pane.failureView == nil)
    }

    @Test func aRendererFailureKeepsTheChildUntilExplicitRetry() throws {
        var preset = Preset(name: "renderer-failure")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "exec /bin/cat"]
        let pane = makePane(preset: preset)
        defer { pane.teardown() }
        let old = try #require(pane.session)
        pane.frameLoop.onRenderingFailure?(Metal4BackendError.gpuCompletionTimedOut)
        let failure = try #require(pane.failureView)
        #expect(!pane.isOperable)
        #expect(!pane.frameLoop.prepareFrame())
        #expect(old.pty.waitForExit(timeout: .seconds(0)) == nil)
        failure.onRetry?()
        #expect(pane.isOperable)
        #expect(pane.session !== old)
    }

    @Test func aBackgroundFailureDoesNotTakeTheActiveRespondersReturnKey() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let activeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        root.addSubview(activeField)
        window.makeFirstResponder(activeField)
        let activeResponder = window.firstResponder
        let failure = PaneFailureView(title: "Test failure", detail: "Test detail", canRetry: true)
        failure.present(in: root, takesFocus: false)
        #expect(window.firstResponder === activeResponder)
        #expect(failure.primaryAction?.keyEquivalent == "")
    }

    /// A toast said "exited" for two seconds; after that a dead pane looked
    /// like a live one not answering. The panel stays until a new session
    /// starts, and says how the session ended.
    @Test(arguments: [
        ("exit 0", ProcessExit.exited(code: 0)),
        ("exit 3", ProcessExit.exited(code: 3)),
        ("kill -TERM $$", ProcessExit.signalled(signal: SIGTERM)),
    ])
    func childExitOnItsOwnShowsTheEndedPanel(script: String, expected: ProcessExit) async throws {
        // A shell that exits the moment it starts, rather than the default
        // login shell plus a typed `exit\n`: real dotfiles can fork
        // long-lived children that keep the pty's slave side open well past
        // the shell's own exit, which would make "EOF observed" a test of
        // this machine's shell configuration instead of of `onChildExit`.
        var preset = Preset(name: "immediate-exit")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", script]
        let pane = makePane(preset: preset)
        defer { pane.teardown() }
        let session = try #require(pane.session)

        #expect(
            await waitUntilTrue(timeout: .seconds(10)) {
                session.pty.waitForExit(timeout: .seconds(0)) != nil
            },
            "the shell should exit on its own")
        #expect(
            await waitUntilTrue(timeout: .seconds(10)) { pane.sessionEndedPanel != nil },
            "expected the panel once the reader loop observes the exit")
        let overlay = try #require(pane.sessionEndedPanel)
        let expectedContent = SessionEnded.content(
            for: expected, isConnection: false, host: nil, program: "sh")
        #expect(overlay.panel.content.title == expectedContent.title)
        #expect(overlay.panel.content.body == expectedContent.body)
        #expect(overlay.panel.accessibilityLabel()?.contains(expectedContent.body) == true)
        // It never takes the keyboard: a key pressed in a dead pane starts
        // nothing.
        #expect(overlay.panel.buttons.allSatisfy { $0.keyEquivalent.isEmpty })
        // Still there later: it is not a toast.
        try await Task.sleep(for: .seconds(3))
        #expect(pane.sessionEndedPanel === overlay && overlay.superview != nil)
        // A new session takes it away.
        pane.rebuildPane(strictRespawn: false)
        #expect(pane.sessionEndedPanel == nil && overlay.superview == nil)
        #expect(pane.session !== session)
    }

    /// Reconnect respawned at the configured grid and font size, so the
    /// remote banner and prompt were laid out at the wrong width before the
    /// resize, and a ⌘+ zoom was lost. A rebuild keeps both.
    @Test func aRebuildKeepsTheGridAndAZoomedFontSize() throws {
        var preset = Preset(name: "rebuild")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "exec /bin/cat"]
        let pane = makePane(preset: preset)
        defer { pane.teardown() }
        pane.didSizeWindow = true
        pane.lastRequestedSize = TerminalSize(rows: 31, columns: 97)
        pane.fontSize = 17
        pane.isFontSizeZoomed = true
        let old = try #require(pane.session)
        pane.rebuildPane(strictRespawn: false)
        let session = try #require(pane.session)
        #expect(session !== old)
        let size = try session.pty.size()
        #expect(size.rows == 31 && size.columns == 97)
        #expect(pane.fontSize == 17)
    }

    /// The connect dialog's host became a recent one on Connect, before
    /// anything connected — a refused host, or one with no shell (a git
    /// host), was offered again. It is recorded once ssh has a terminal on
    /// the server, which it shows by putting this one in raw mode; a
    /// password prompt turns echo off and is not that.
    @Test(arguments: [
        ("stty raw -echo; exec /bin/cat", true),
        ("stty -echo; exec /bin/cat", false),
    ])
    func aConnectionIsRecordedOnceEstablished(script: String, records: Bool) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-established-\(UUID().uuidString)")
            .appendingPathComponent("recent-hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = RecentHostsStore(fileURL: url)
        var preset = Preset(name: "box")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", script]
        preset.connectTarget = try SSHTarget.parse(host: "box", user: "deploy", port: "").get()
        let pane = makePane(preset: preset)
        defer { pane.teardown() }
        pane.remote.recentHosts = store
        if records {
            #expect(await waitUntilTrue(timeout: .seconds(5)) { !store.targets.isEmpty })
            #expect(store.targets.map(\.displayName) == ["deploy@box"])
        } else {
            try await Task.sleep(for: .milliseconds(2500))
            #expect(store.targets.isEmpty)
        }
    }

    @Test func childExitDuringTeardownShowsNoToast() async throws {
        let pane = makePane()
        let session = try #require(pane.session)
        let pid = session.pty.processIdentifier

        pane.teardown()

        #expect(
            await waitUntilTrue(timeout: .seconds(10)) { kill(pid, 0) == -1 && errno == ESRCH },
            "teardown's SIGHUP should still reap the child")
        // The reader loop's `onChildExit` fires for this exit exactly as it
        // does for a self-initiated one; only `didTeardown` tells them apart.
        // Give it a moment to have fired and settle, then assert no toast
        // landed on a pane the user already closed.
        try await Task.sleep(for: .milliseconds(200))
        #expect(toastText(in: pane) == nil, "teardown must not surface a toast for its own pane")
        #expect(pane.sessionEndedPanel == nil, "nor the ended panel")
    }

    /// `await Task.sleep` between checks, not `Thread.sleep`: the suite is
    /// `@MainActor`, and `noteChildExit`'s reaction is itself a `@MainActor`
    /// `Task` — spinning the main thread with a blocking sleep would starve
    /// that task's executor and this would never observe it land.
    private func waitUntilTrue(
        timeout: Duration, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = SuspendingClock.now + timeout * testTimeoutScale
        while SuspendingClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Finds the toast's text without reaching into `TerminalView`'s
    /// private `toastLayer` storage — the same black-box check a screenshot
    /// would make, walking the visible layer tree for the `CATextLayer`
    /// `showToast` installs.
    private func toastText(in pane: ViewController) -> String? {
        guard let root = pane.terminalView?.layer else { return nil }
        return Self.firstTextLayerString(in: root)
    }

    private static func firstTextLayerString(in layer: CALayer) -> String? {
        for sublayer in layer.sublayers ?? [] {
            if let text = sublayer as? CATextLayer {
                // `showToast` sets `string` to an `NSAttributedString`, not a
                // plain `String`.
                if let attributed = text.string as? NSAttributedString {
                    return attributed.string
                }
                if let plain = text.string as? String {
                    return plain
                }
            }
            if let found = firstTextLayerString(in: sublayer) {
                return found
            }
        }
        return nil
    }
}
