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
@testable import CortaTerminal

/// An input method composes through the search field's *field editor* — the
/// shared `NSTextView` AppKit hands an `NSTextField` while it edits — so the
/// marked text lives there, not on the field. These drive the real editor:
/// `setMarkedText` is what an input method calls, and the Esc monitor and the
/// text-change delegate then see the state a Pinyin or Zhuyin composition puts
/// them in. The input method that consumes Esc itself is human-only (a unit
/// test cannot run one); what is checked here is that the bar leaves Esc to it
/// and starts no sweep on the preedit.
///
/// Every window test asks the window for its field editor and makes the field
/// first responder explicitly, then asserts both `currentEditor()` and
/// `hasMarkedText()`. Nothing waits on a debounced sweep landing or on a
/// window the test host happened to key: the same tests run inside the whole
/// `Unit` plan, where the run's start is busy and a background sweep can be
/// scheduled long before it lands (`#522` CI).
@MainActor
@Suite(.serialized)
struct PaneSearchCompositionTests {
    private func makeHost() -> SearchTestHost {
        let host = SearchTestHost()
        host.print("P04MARKER\n")
        return host
    }

    /// An input method's marked text is AppKit's field-editor state, not the
    /// search field's query. Esc belongs to the composition: the monitor must
    /// leave it for the field editor, so the input method can cancel the
    /// preedit, and the bar stays on the query and results it had. Only an Esc
    /// with nothing marked closes it.
    @Test func escapeDuringCompositionCancelsOnlyTheComposition() throws {
        let host = makeHost()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.view
        defer {
            host.search.close()
            window.close()
        }
        host.search.show()
        let field = try #require(host.search.field)

        // What the bar showed before the composition: a query and its match,
        // seeded synchronously. Waiting for the debounced sweep to land here
        // made the test depend on the full plan's background load, not on the
        // monitor and the field editor it is about (#522 CI).
        field.stringValue = "P04MARKER"
        host.search.applyResults(
            .init(
                matches: [
                    SelectionRange(
                        start: SelectionPoint(row: 0, column: 0),
                        end: SelectionPoint(row: 0, column: 8)),
                ],
                status: .complete),
            generation: host.search.generation, scrollsToMatch: false, totalPushed: 0)
        let shownCount = host.search.barModel.countText
        #expect(!shownCount.isEmpty)

        // A real input method marks text through the window's field editor.
        // It is asked for and made first responder explicitly, and both that
        // and the marked state are asserted, so the test does not depend on a
        // window or an input context the test host left in some state.
        let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        #expect(window.makeFirstResponder(field), "the search field takes the keyboard")
        #expect(field.currentEditor() === editor, "the field editor is the one editing")
        editor.setMarkedText(
            "zhuang", selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText(), "the input method's preedit is marked")
        #expect(host.search.isComposingText)

        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
        let handler = PaneSearch.keyMonitorHandler(for: host.search)
        // The event reaches the input method untouched, and the bar is still
        // there with the results it showed before the composition began.
        #expect(handler(escape) === escape)
        #expect(host.search.bar != nil)
        #expect(host.search.matches.count == 1)
        #expect(host.search.barModel.countText == shownCount)

        // The input method ends the composition; the next Esc, with no marked
        // text left, closes the bar.
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        #expect(!host.search.isComposingText)
        #expect(handler(escape) == nil)
        #expect(host.search.bar == nil)
    }

    /// The delegate path the issue names: a text change arriving while the
    /// field editor holds marked text starts no sweep, so nothing is searched
    /// for and no viewport moves, and output arriving meanwhile refreshes
    /// nothing either. The commit's change sweeps the committed text once.
    @Test func aChangeWhileMarkedSweepsNothingAndTheCommitSweepsOnce() async throws {
        let host = SearchTestHost()
        // Pushed into the scrollback, so a wrongly-started sweep for the
        // preedit would both find something and move the viewport to it.
        host.print("P04MARKER\n")
        host.print((1...20).map { "filler \($0)\n" }.joined())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.view
        defer {
            host.search.close()
            window.close()
        }
        host.search.show()
        let field = try #require(host.search.field)
        let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        #expect(window.makeFirstResponder(field), "the search field takes the keyboard")
        #expect(field.currentEditor() === editor, "the field editor is the one editing")
        let generation = host.search.generation

        editor.setMarkedText(
            "P04", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText(), "the input method's preedit is marked")
        #expect(host.search.isComposingText)
        host.search.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
        host.search.scheduleBackgroundRefresh()
        #expect(host.search.task == nil, "no sweep starts while text is marked")
        #expect(host.search.generation == generation)
        #expect(host.search.matches.isEmpty)
        #expect(host.scrollOffset == 0, "the viewport stays where the user left it")

        // Committing the candidate replaces the marked text and schedules one
        // sweep; joining that sweep is what proves it searched the text, with
        // no clock of its own.
        editor.insertText(
            "P04MARKER", replacementRange: NSRange(location: NSNotFound, length: 0))
        let sweep = try #require(host.search.task, "the commit starts exactly one sweep")
        #expect(host.search.generation == generation + 1)
        await sweep.value
        #expect(host.search.matches.count == 1)
        #expect(host.scrollOffset > 0, "the commit's sweep found the scrollback match")
    }

    /// The gate must not touch ordinary typing: with nothing marked, a change
    /// still searches after the debounce.
    @Test func typingWithoutMarkedTextStillSweeps() async throws {
        let host = makeHost()
        defer { host.search.close() }
        host.search.show()
        let field = try #require(host.search.field)
        field.stringValue = "P04MARKER"
        host.search.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
        let sweep = try #require(host.search.task, "a change without marked text searches")
        await sweep.value
        #expect(host.search.matches.count == 1)
    }
}
