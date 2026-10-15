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

/// A pane drops its selection on the first frame after the program rewrites
/// a row under it, and keeps it while output only scrolls (#341).
@MainActor
struct SelectionRewriteTests {
    private func numbered() -> Terminal {
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array((0..<10).map { "\($0)" }.joined(separator: "\r\n").utf8))
        return terminal
    }

    private let row2 = SelectionRange(
        start: SelectionPoint(row: 2, column: 0), end: SelectionPoint(row: 2, column: 5))

    @Test func aRewrittenRowDropsTheSelectionAndScrollingDoesNot() {
        let pane = ViewController()
        var terminal = numbered()
        pane.pointer.setSelection(row2, in: terminal.grid)

        terminal.feed(Array("\r\nscrolled".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil, "scrolling keeps it on its text")

        // The selected text is now screen row 1 (line 2): erase it in place.
        terminal.feed(Array("\u{1B}7\u{1B}[2;1H\u{1B}[2K\u{1B}8".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection == nil)
    }

    /// Recorded as it is made: a redraw that lands before the next frame is
    /// a change, not the baseline.
    @Test func aRewriteBeforeTheFirstFrameIsCaught() {
        let pane = ViewController()
        var terminal = numbered()
        pane.pointer.setSelection(row2, in: terminal.grid)
        terminal.feed(Array("\u{1B}7\u{1B}[3;1H\u{1B}[2Knew\u{1B}8".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection == nil)
    }

    @Test func reselectingTheSameRangeRecordsItAfresh() {
        let pane = ViewController()
        var terminal = numbered()
        pane.pointer.setSelection(row2, in: terminal.grid)
        terminal.feed(Array("\u{1B}7\u{1B}[3;1Hz\u{1B}8".utf8))
        // The same range selected again over the new text: that is the baseline now.
        pane.pointer.setSelection(row2, in: terminal.grid)
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil)
    }

    /// ⌘A covers the blank rows below the cursor; output landing there does
    /// not rewrite anything it selected.
    @Test func aSelectAllSurvivesOutputBelowThePrompt() {
        let pane = ViewController()
        var terminal = Terminal(rows: 6, columns: 20)
        terminal.feed(Array("$ ".utf8))
        let all = SelectionRange(
            start: SelectionPoint(row: 0, column: 0), end: SelectionPoint(row: 5, column: 19))
        pane.pointer.setSelection(all, in: terminal.grid)
        terminal.feed(Array("\r\nline one\r\nline two".utf8))
        pane.pointer.dropSelectionIfRewritten(in: terminal.grid)
        #expect(pane.selection != nil)
    }
}

/// A real child and a visible pane exercise the output-to-frame wiring,
/// beyond comparing synthetic grids. All shell state is local to the child.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct SelectionLiveOutputTests {
    private func waitUntilTrue(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = SuspendingClock.now + timeout * testTimeoutScale
        while SuspendingClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test(arguments: ["selected", "rewritten"], ["frame", "services", "accessibility"])
    func aLiveRedrawValidatesTheSelection(text: String, reader: String) async throws {
        var preset = Preset(name: "selection-redraw")
        preset.shell = "/bin/sh"
        preset.arguments = ["-c", """
            stty -echo
            printf '\\033[2J\\033[Hselected\\r\\nREADY'
            while IFS= read -r text; do
                printf '\\033[1;1H\\033[2K%s\\033[3;1HDONE' "$text"
            done
            """]
        let pane = ViewController()
        pane.preset = preset
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.orderFront(nil)
        defer { pane.teardown(); window.close() }
        let session = try #require(pane.session)
        var batches = 0
        let onBatch = pane.frameLoop.onOutputBatch
        pane.frameLoop.onOutputBatch = { batches += 1; onBatch?() }
        let ready = await waitUntilTrue(timeout: .seconds(5)) {
            _ = pane.frameLoop.prepareFrame()
            return session.snapshot().logicalLines().contains { $0.text.contains("READY") }
        }
        try #require(ready)
        let range = SelectionRange(start: SelectionPoint(row: 0, column: 0), end: SelectionPoint(row: 0, column: 7))
        #expect(Selection.text(of: range, in: session.snapshot()) == "selected")
        pane.pointer.setSelection(range, in: session.snapshot())
        let before = batches
        if reader != "frame" { pane.frameLoop.suspendRendering() }
        session.write(Array("\(text)\n".utf8))
        let redrawn = await waitUntilTrue(timeout: .seconds(5)) {
            _ = pane.frameLoop.prepareFrame()
            let received = session.snapshot().logicalLines().contains { $0.text.contains("DONE") }
            return received && (reader != "frame" || (batches > before && (text == "selected" || pane.selection == nil)))
        }
        try #require(redrawn)
        #expect(Selection.text(of: range, in: session.snapshot()) == String(text.prefix(8)))
        if reader == "services" {
            #expect(pane.commands.selectedText() == (text == "selected" ? "selected" : nil))
        } else if reader == "accessibility" {
            let snapshot = try #require(pane.terminalView.accessibilitySnapshotProvider?())
            #expect(snapshot.selectedRange.length == (text == "selected" ? 8 : 0))
        }
        #expect((pane.selection != nil) == (text == "selected"))
    }
}
