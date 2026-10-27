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
import Testing
@testable import Corta

extension TerminalViewIMETests {
    @Test func firstRectStaysCorrectAfterTheWindowMoves() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        view.cursorRectProvider = { CGRect(x: 16, y: 34, width: 8, height: 17) }
        let before = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        window.setFrameOrigin(NSPoint(x: 500, y: 650))
        let after = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(after.origin.x - before.origin.x == 300)
        #expect(after.origin.y - before.origin.y == 350)
    }

    @Test func firstRectIsZeroWithoutACursorOrWindow() {
        let view = Self.makeView()
        #expect(view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil) == .zero)
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        // A cursor rect but no window: still no answer.
        #expect(view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil) == .zero)
    }

    // MARK: - Audit: splits, resize and focus changes

    /// A divider drag moves a pane inside its window without the window
    /// itself moving; the candidate window's anchor follows because it is
    /// recomputed from live geometry on every query.
    @Test func firstRectFollowsThePaneMovingWithinTheWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 800, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        view.cursorRectProvider = { CGRect(x: 16, y: 34, width: 8, height: 17) }
        let before = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        view.setFrameOrigin(NSPoint(x: 400, y: 0))
        let after = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(after.origin.x - before.origin.x == 400)
        #expect(after.origin.y == before.origin.y)
    }

    /// A window resize (fullscreen transitions included) changes the pane's
    /// bounds, and `firstRect` is recomputed from the live geometry rather
    /// than cached — the candidate window must not stay where the pane used
    /// to be.
    ///
    /// The invariant is stated against the window's *top* edge, not as a
    /// fixed screen delta. `TerminalView` is flipped and the cursor cell sits
    /// a fixed distance below the pane's top, so what a resize must preserve
    /// is that distance; which edge AppKit holds still while it resizes is
    /// its business — asserting a hard-coded +100 would assert AppKit's
    /// choice instead of Corta's behaviour.
    @Test func firstRectStaysCorrectAfterTheWindowResizes() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        let cell = CGRect(x: 16, y: 34, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        let before = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let topBefore = window.frame.maxY - before.maxY

        window.setContentSize(NSSize(width: 400, height: 400))
        view.frame = window.contentView!.bounds  // the app's constraints do this
        #expect(view.bounds.height == 400)

        let after = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(after.origin.x == before.origin.x)
        #expect(window.frame.maxY - after.maxY == topBefore)
        // Recomputed, not cached: the answer is the current geometry's.
        #expect(after == window.convertToScreen(view.convert(cell, to: nil)))
    }

    /// A resize reflow moves the cursor; the provider is re-read on every
    /// query, so the next firstRect lands on the new cell — nothing cached.
    @Test func firstRectTracksANewCursorCellWithoutCaching() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        var cell = CGRect(x: 16, y: 34, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        let before = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        cell = CGRect(x: 0, y: 17, width: 8, height: 17)
        let after = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(after != before)
        #expect(after == window.convertToScreen(view.convert(cell, to: nil)))
    }

    /// Mid-composition geometry changes (a resize reflow, a split moving
    /// the pane) re-anchor the preedit overlay on the next preedit update.
    @Test func preeditOverlayFollowsTheCursorAcrossGeometryChanges() {
        let view = Self.makeView()
        var cell = CGRect(x: 40, y: 17, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        view.setMarkedText(
            "zh", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first else {
            Issue.record("no preedit overlay was added")
            return
        }
        #expect(overlay.frame.origin == cell.origin)
        cell = CGRect(x: 0, y: 68, width: 8, height: 17)
        view.setMarkedText(
            "zho", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(overlay.frame.origin == cell.origin)
    }

    /// ⌘=/⌘- mid-composition: the next preedit update carries the new cell
    /// metrics and font size rather than the ones the composition opened
    /// with.
    ///
    /// The cell arrives through `cursorRectProvider`, which the shell backs
    /// with the renderer's live `pointMetrics` — so a font-size change is a
    /// *taller cursor rect*, and that is what has to reach the overlay. The
    /// overlay keeps no copy of the cell size of its own: sizing comes from
    /// the rect.
    @Test func preeditOverlayTracksCellSizeChanges() {
        let view = Self.makeView()
        var cell = CGRect(x: 0, y: 0, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        view.setMarkedText(
            "zh", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first else {
            Issue.record("no preedit overlay was added")
            return
        }
        #expect(overlay.frame.height >= 17)

        cell = CGRect(x: 0, y: 0, width: 16, height: 34)
        view.cellSize = CGSize(width: 16, height: 34)
        view.setMarkedText(
            "zho", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(overlay.frame.height >= 34)
        #expect(overlay.frame.width >= 16)
    }

    /// AppKit does not clip subviews to their superview: a preedit at the
    /// last column, left unclamped, would paint over the divider and the
    /// sibling pane in a split.
    @Test func preeditOverlayStaysInsideThePane() {
        let view = Self.makeView()  // 200 points wide
        view.cursorRectProvider = { CGRect(x: 192, y: 0, width: 8, height: 17) }
        view.setMarkedText(
            "中文测试输入", selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first else {
            Issue.record("no preedit overlay was added")
            return
        }
        #expect(overlay.frame.maxX <= view.bounds.maxX)
    }

    /// Composition state lives on each pane's own overlay subview: one pane
    /// composing never shows up as marked text in another.
    @Test func markedTextStateIsPerPane() {
        let first = Self.makeView()
        let second = Self.makeView()
        first.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        first.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(first.hasMarkedText())
        #expect(!second.hasMarkedText())
        #expect(second.markedRange().location == NSNotFound)
    }

    /// Focus moving to a sibling pane ends this pane's composition: the
    /// preedit goes with it rather than sitting stale on a pane the user is
    /// no longer typing into — and nothing about it leaks into the pane
    /// taking over. Discarded, not committed: half-composed input must
    /// never reach the PTY.
    @Test func focusSwitchToAnotherPaneDiscardsTheComposition() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 800, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let first = Self.makeView()
        let second = Self.makeView()
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        first.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        var bytes: [UInt8] = []
        first.onKeyBytes = { bytes += $0 }
        window.makeFirstResponder(first)
        first.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(first.hasMarkedText())

        window.makeFirstResponder(second)
        #expect(!first.hasMarkedText())
        #expect(first.markedRange().location == NSNotFound)
        #expect(!second.hasMarkedText())
        #expect(bytes.isEmpty)
        let overlay = first.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first
        #expect(overlay?.isHidden ?? true)

        // Refocusing starts clean: a live input context, no leftover preedit.
        window.makeFirstResponder(first)
        #expect(first.inputContext != nil)
        #expect(!first.hasMarkedText())
    }

    @Test func candidateAnchorFollowsPreeditSelectionAndReanchorsWithoutAnotherKey() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        var cell = CGRect(x: 16, y: 34, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.selectedRange() == NSRange(location: 5, length: 0))
        let start = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let caret = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        #expect(caret.minX > start.minX + cell.width)
        #expect(caret.minY == start.minY)
        cell.origin = CGPoint(x: 40, y: 68)
        view.refreshInputCompositionGeometry()
        let moved = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        #expect(moved.minX - caret.minX == 24)
        #expect(moved.minY - caret.minY == -34)
        #expect(view.inputCompositionRect?.origin == cell.origin)
        #expect(view.lastInputCompositionScreenRect == moved)
        let overlay = try #require(view.subviews.compactMap { $0 as? MarkedTextOverlayView }.first)
        #expect(overlay.markedText?.string == "zhong")
    }
}

extension TerminalViewIMETests {
    @Test func candidateRangeClampsAndGeometryRefreshUsesTheNewFont() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        view.cursorRectProvider = { CGRect(x: 8, y: 17, width: 8, height: 17) }
        var fontSize: CGFloat = 12
        view.preeditFontProvider = { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        var actual = NSRange(location: 0, length: 0)
        let end = view.firstRect(forCharacterRange: NSRange(location: 999, length: 999), actualRange: &actual)
        #expect(actual == NSRange(location: 5, length: 0))
        #expect(end == before)
        fontSize = 24
        view.refreshInputCompositionGeometry()
        let after = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        #expect(after.minX > before.minX)
        #expect(after.height > before.height)
        view.unmarkText()
        #expect(view.selectedRange().location == NSNotFound)
        #expect(view.lastInputCompositionScreenRect == nil)
    }

    // MARK: - NSTextInputClient read-side defaults

    @Test func readSideQueriesExposeNoBackingStore() {
        let view = Self.makeView()
        #expect(view.selectedRange().location == NSNotFound)
        #expect(view.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 1), actualRange: nil) == nil)
        #expect(view.characterIndex(for: .zero) == NSNotFound)
        #expect(view.validAttributesForMarkedText().contains(.underlineStyle))
    }
}
