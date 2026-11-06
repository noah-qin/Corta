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

/// Where a click sends the keyboard, and what a plain click may open.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct PaneClickTests {
    private func windowed() -> (TerminalPaneViewController, NSWindow) {
        let pane = TerminalPaneViewController()
        pane.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.orderFront(nil)
        return (pane, window)
    }

    @Test("a click in a pane takes the keyboard back unless its own search bar has it")
    func clickFocusesUnlessTheBarHasTheKeyboard() throws {
        let (pane, window) = windowed()
        defer { pane.teardown(); window.close() }
        let view = try #require(pane.terminalView)
        pane.search.show()
        #expect(pane.search.hasKeyboardFocus, "the bar opens with the keyboard")
        view.takeFocusForClick()
        #expect(pane.search.hasKeyboardFocus, "clicking a match must not strand the bar")

        // The keyboard goes elsewhere, as to another pane; the bar stays open.
        let elsewhere = NSTextField()
        pane.view.addSubview(elsewhere)
        defer { elsewhere.removeFromSuperview() }
        window.makeFirstResponder(elsewhere)
        #expect(pane.search.bar != nil)
        #expect(!pane.search.hasKeyboardFocus)
        view.takeFocusForClick()
        #expect(window.firstResponder === view, "typing would otherwise go to the other pane")
    }

    private func waitForDirectory(_ session: TerminalSession) async -> Bool {
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while session.workingDirectory == nil, SuspendingClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return session.workingDirectory != nil
    }

    /// `link-activation = click` is for URLs: a click also focuses a pane and
    /// clears a selection, and a `path:line` starts the configured editor.
    @Test("a plain click does not open a `path:line`, whatever link-activation says")
    func plainClickLeavesReferencesAlone() async throws {
        let store = ConfigurationStore.shared
        let previous = store.configuration
        defer { store.update { $0 = previous } }
        #expect(store.update {
            $0.linkActivation = .click
            $0.openFileCommand = "/usr/bin/true {file}"
        })
        let (pane, window) = windowed()
        defer { pane.teardown(); window.close() }
        let session = try #require(pane.session)
        let view = try #require(pane.terminalView)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target.swift")
        try Data().write(to: file)
        // A local directory reported, or no path counts as a file here at all.
        session.write(Array("printf '\\033]7;file://%s%s\\033\\\\' \"$(hostname)\" '\(directory.path)'\n".utf8))
        let reported = await waitForDirectory(session)
        try #require(reported)
        session.write(Array("echo '\(file.path):3'\n".utf8))

        // Wherever the output landed, by asking the same detection a click uses.
        func event(at point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: view.convert(point, to: nil), modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0)!
        }
        var found: NSEvent?
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while found == nil, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            for y in stride(from: CGFloat(4), to: view.bounds.height, by: 6) {
                let candidate = event(at: CGPoint(x: 40, y: y))
                if pane.pointer.detectedReferenceUnder(candidate, in: view) != nil {
                    found = candidate
                    break
                }
            }
        }
        let click = try #require(found, "the reference should be on screen")
        #expect(!pane.pointer.openLinkOnPlainClick(click, in: view))
    }
}
