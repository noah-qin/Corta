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
import CortaTerminal

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

    @Test func childExitOnItsOwnShowsAToast() async throws {
        // A shell that exits the moment it starts, rather than the default
        // login shell plus a typed `exit\n`: real dotfiles can fork
        // long-lived children that keep the pty's slave side open well past
        // the shell's own exit, which would make "EOF observed" a test of
        // this machine's shell configuration instead of of `onChildExit`.
        var preset = Preset(name: "immediate-exit")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", "exit 0"]
        let pane = makePane(preset: preset)
        let session = try #require(pane.session)

        #expect(
            await waitUntilTrue(timeout: .seconds(10)) {
                session.pty.waitForExit(timeout: .seconds(0)) != nil
            },
            "the shell should exit on its own after `exit`")
        #expect(
            await waitUntilTrue(timeout: .seconds(10)) { self.toastText(in: pane) != nil },
            "expected a toast once the reader loop observes the exit")
        #expect(toastText(in: pane) == L10n.text("toast.shellExited"))

        pane.teardown()
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
