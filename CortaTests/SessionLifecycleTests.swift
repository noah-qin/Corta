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
    func anIOFailureOffersExplicitRetryAndIgnoresOldCallbacks(operation: TerminalSession.IOFailure.Operation) async throws {
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
    /// like a live one not answering. The bar stays until a new session
    /// starts, and says how the session ended.
    @Test(arguments: [
        ("exit 0", ChildExit.exited(code: 0)),
        ("exit 3", ChildExit.exited(code: 3)),
        ("kill -TERM $$", ChildExit.signalled(signal: SIGTERM)),
    ])
    func childExitOnItsOwnShowsTheEndedBar(script: String, expected: ChildExit) async throws {
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
            await waitUntilTrue(timeout: .seconds(10)) { pane.sessionEndedBar != nil },
            "expected the bar once the reader loop observes the exit")
        let bar = try #require(pane.sessionEndedBar)
        #expect(bar.message == SessionEndedBar.message(for: expected, isConnection: false))
        #expect(bar.accessibilityLabel() == bar.message)
        // Still there later: it is not a toast.
        try await Task.sleep(for: .seconds(3))
        #expect(pane.sessionEndedBar === bar && bar.superview != nil)
        // A new session takes it away.
        pane.rebuildPane(strictRespawn: false)
        #expect(pane.sessionEndedBar == nil && bar.superview == nil)
        #expect(pane.session !== session)
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
        #expect(pane.sessionEndedBar == nil, "nor the ended bar")
    }

    /// `await Task.sleep` between checks, not `Thread.sleep`: the suite is
    /// `@MainActor`, and `noteChildExit`'s reaction is itself a `@MainActor`
    /// `Task` — spinning the main thread with a blocking sleep would starve
    /// that task's executor and this would never observe it land.
    private func waitUntilTrue(
        timeout: Duration, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout * testTimeoutScale
        while ContinuousClock.now < deadline {
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
