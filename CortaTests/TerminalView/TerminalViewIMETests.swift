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

/// IME routing and marked-text handling. Everything here runs
/// without a live input method — the routing decision is a pure function of
/// the event, marked text and committed text are exercised by calling the
/// `NSTextInputClient` methods exactly as an input context would, and
/// `firstRect` is checked against a real (never ordered-in) window.
@MainActor
struct TerminalViewIMETests {
    private static func keyEvent(
        characters: String, charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false, keyCode: keyCode)!
    }

    static func makeView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.cellSize = CGSize(width: 8, height: 17)
        return view
    }

    // MARK: - Routing

    @Test func commandAndControlEventsBypassTheIME() {
        #expect(!TerminalView.routesEventThroughIME(
            Self.keyEvent(characters: "c", modifiers: .control)))
        #expect(!TerminalView.routesEventThroughIME(
            Self.keyEvent(characters: "v", modifiers: .command)))
        #expect(!TerminalView.routesEventThroughIME(
            Self.keyEvent(characters: "c", modifiers: [.command, .control])))
    }

    @Test func plainAndShiftedEventsAreOfferedToTheIME() {
        #expect(TerminalView.routesEventThroughIME(Self.keyEvent(characters: "a")))
        // ⇧9 must reach the IME: with an input source active it may compose,
        // without one it falls through to the direct path as "(".
        #expect(TerminalView.routesEventThroughIME(
            Self.keyEvent(characters: "(", charactersIgnoringModifiers: "9", modifiers: .shift)))
        // ⌥ is text input on macOS (⌥e starts a dead-key compose), so it routes too.
        #expect(TerminalView.routesEventThroughIME(
            Self.keyEvent(characters: "´", modifiers: .option)))
    }

    /// With `option-as-meta` on, ⌥F must not type `ƒ`.
    ///
    /// The encoder handles `option-as-meta`, but only for an event that
    /// reaches it. An ⌥-only press carries neither ⌘ nor ⌃, so
    /// it was offered to the input context, macOS composed the layout's
    /// alternate character, and it came back through `insertText`. The
    /// encoder had a test; the dispatch that feeds it did not.
    @Test func optionEventsBypassTheIMEOnlyWhenOptionIsMeta() {
        let optionF = Self.keyEvent(
            characters: "ƒ", charactersIgnoringModifiers: "f", modifiers: .option)
        // Off: ⌥ is text input and must keep reaching the IME, which is what
        // dead keys and every international layout depend on.
        #expect(TerminalView.routesEventThroughIME(optionF, optionAsMeta: false))
        // On: it has to reach the encoder, which sends `ESC f`.
        #expect(!TerminalView.routesEventThroughIME(optionF, optionAsMeta: true))
        // Without ⌥ the setting changes nothing either way.
        let plainA = Self.keyEvent(characters: "a")
        #expect(TerminalView.routesEventThroughIME(plainA, optionAsMeta: true))
        #expect(TerminalView.routesEventThroughIME(plainA, optionAsMeta: false))
        // ⌘ still wins regardless.
        let commandV = Self.keyEvent(characters: "v", modifiers: [.command, .option])
        #expect(!TerminalView.routesEventThroughIME(commandV, optionAsMeta: true))
        #expect(!TerminalView.routesEventThroughIME(commandV, optionAsMeta: false))
    }

    /// A command the context answers the key it is handling with is that
    /// key's terminal sequence — whatever the selector, `noop:` and
    /// `scrollToBeginningOfDocument:` included, which used to be dropped.
    @Test func aCommandForTheKeyBeingHandledIsEncodedFromTheKey() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.keyEventInInputContext = Self.keyEvent(
            characters: "\u{F729}", modifiers: .function, keyCode: 115)
        view.doCommand(by: #selector(NSResponder.scrollToBeginningOfDocument(_:)))
        #expect(bytes == Array("\u{1B}[H".utf8))
        bytes = []
        view.keyEventInInputContext = Self.keyEvent(
            characters: "\u{F704}", modifiers: .function, keyCode: 122)
        view.doCommand(by: NSSelectorFromString("noop:"))
        #expect(bytes == Array("\u{1B}OP".utf8))
        // With no key in hand (a candidate window), the selector map stands.
        bytes = []
        view.keyEventInInputContext = nil
        view.doCommand(by: #selector(NSResponder.scrollToBeginningOfDocument(_:)))
        #expect(bytes.isEmpty)
    }

    /// Terminal keys still reach the IME first: one composing in its own
    /// panel (`hasMarkedText()` cannot see it) needs them.
    @Test func terminalKeysAreStillOfferedToTheIME() {
        let home = Self.keyEvent(characters: "\u{F729}", modifiers: .function, keyCode: 115)
        #expect(TerminalView.routesEventThroughIME(home))
        #expect(TerminalView.isTerminalKey(home))
        #expect(TerminalView.isTerminalKey(Self.keyEvent(characters: "\u{1B}", keyCode: 53)))
        #expect(!TerminalView.isTerminalKey(Self.keyEvent(characters: "a")))
    }

    /// A kitty release goes out only for a press the child saw: the search
    /// bar's Escape, or one an IME used, must not report a release alone.
    @Test func aReleaseIsReportedOnlyForADeliveredPress() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.keyboardEnhancements = { [.disambiguate, .reportEventTypes] }
        func escape(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53)!
        }
        view.keyUp(with: escape(.keyUp))
        #expect(bytes.isEmpty, "no press was delivered")
        view.deliverBytes(for: escape(.keyDown))
        #expect(bytes == Array("\u{1B}[27u".utf8))
        bytes = []
        view.keyUp(with: escape(.keyUp))
        #expect(bytes == Array("\u{1B}[27;1:3u".utf8))
    }

    /// End to end through a real input context — which, for every input
    /// source, consumes these keys and answers with `moveWordLeft:`,
    /// `scrollToBeginningOfDocument:`, `deleteForward:`, `complete:` and the
    /// like. Each must still reach the child as its terminal sequence.
    @Test func terminalKeysReachTheChildThroughARealInputContext() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        try #require(view.inputContext != nil)
        var sent: [UInt8] = []
        view.onKeyBytes = { sent += $0 }
        func press(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> [UInt8] {
            sent = []
            view.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
            return sent
        }
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(press("\u{F729}", 115, .function) == Array("\u{1B}[H".utf8))
        #expect(press("\u{F72B}", 119, .function) == Array("\u{1B}[F".utf8))
        #expect(press("\u{F72C}", 116, .function) == Array("\u{1B}[5~".utf8))
        #expect(press("\u{F728}", 117, .function) == Array("\u{1B}[3~".utf8))
        #expect(press("\u{F708}", 96, .function) == Array("\u{1B}[15~".utf8))
        #expect(press("\u{F704}", 122, .function) == Array("\u{1B}OP".utf8))
        #expect(press("\u{F702}", 123, arrow.union(.option)) == Array("\u{1B}[1;3D".utf8))
        #expect(press("\u{F702}", 123, arrow.union(.shift)) == Array("\u{1B}[1;2D".utf8))
        #expect(press("\u{F700}", 126, arrow) == Array("\u{1B}[A".utf8))
        #expect(press("\u{7F}", 51, .option) == [0x1B, 0x7F])
        #expect(press("\r", 36, []) == [0x0D])
        // Application cursor keys (DECCKM) survive the trip.
        view.applicationCursorKeys = { true }
        #expect(press("\u{F700}", 126, arrow) == Array("\u{1B}OA".utf8))
    }

    /// A command the IME resolved for a terminal key uses the key itself, so
    /// LNM and DECCKM apply; without a key event the selector map remains.
    @Test func doCommandHonoursNewLineMode() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.isNewLineMode = { true }
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(bytes == [0x0D, 0x0A])
    }

    /// The other half, end to end through the view: with the setting on, an
    /// ⌥F press produces `ESC f` rather than the composed character.
    @Test func optionFSendsMetaFWhenOptionIsMeta() {
        let view = Self.makeView()
        var sent: [UInt8] = []
        view.onKeyBytes = { sent += $0 }
        view.optionAsMeta = { true }
        view.keyDown(
            with: Self.keyEvent(
                characters: "ƒ", charactersIgnoringModifiers: "f", modifiers: .option))
        #expect(sent == [0x1B, UInt8(ascii: "f")], "got \(sent)")

        sent = []
        view.optionAsMeta = { false }
        view.keyDown(
            with: Self.keyEvent(
                characters: "ƒ", charactersIgnoringModifiers: "f", modifiers: .option))
        #expect(sent == Array("ƒ".utf8), "got \(sent)")
    }

    @Test func unhandledKeyFallsThroughToDirectBytes() {
        // No window, no input context — the IME path declines and keyDown
        // translates the key directly.
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.keyDown(with: Self.keyEvent(characters: "a"))
        #expect(bytes == Array("a".utf8))
    }

    @Test func controlKeyDeliversItsC0ByteWithNoIMEActive() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.keyDown(with: Self.keyEvent(
            characters: "\u{3}", charactersIgnoringModifiers: "c", modifiers: .control))
        #expect(bytes == [0x03])
    }

    @Test func commandGesturesStillFireBeforeAnyRouting() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        var pasted = false
        var scrolled: ScrollGesture?
        view.onKeyBytes = { bytes += $0 }
        view.onPaste = { pasted = true }
        view.onScroll = { scrolled = $0 }
        view.keyDown(with: Self.keyEvent(characters: "v", modifiers: .command))
        #expect(pasted)
        #expect(bytes.isEmpty)
        #expect(scrolled == nil)
        // ⇧Home, the key `scroll-to-top` is bound to. ⌘↑ is Previous
        // Command's, and no longer scrolls here.
        view.keyDown(with: Self.shiftHome())
        guard case .some(.toTop) = scrolled else {
            Issue.record("expected .toTop")
            return
        }
        #expect(bytes.isEmpty)
    }

    /// An unbound command hands its key to the child. With `bind.paste`
    /// and `bind.scroll-to-top` cleared, neither gesture fires and both
    /// keystrokes encode as ordinary input, which is what unbinding is for.
    @Test func unbindingHandsTheKeystrokeToTheChild() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        var pasted = false
        var scrolled: ScrollGesture?
        view.onKeyBytes = { bytes += $0 }
        view.onPaste = { pasted = true }
        view.onScroll = { scrolled = $0 }
        let (configuration, _) = Configuration.parse(
            """
            bind.paste =
            bind.scroll-to-top =
            """)
        view.keybindings = { configuration.keybindings }

        view.keyDown(with: Self.keyEvent(characters: "v", modifiers: .command))
        #expect(!pasted)
        #expect(bytes == Array("v".utf8))

        // ⇧Home carries neither ⌘ nor ⌃, so once it is no longer a scroll
        // gesture it takes the ordinary route and is offered to the input
        // context first. The bytes it ends up sending are pinned in
        // `TerminalViewKeyEncodingTests`; what matters here is that the
        // gesture no longer intercepts it.
        view.keyDown(with: Self.shiftHome())
        #expect(scrolled == nil)
    }
}

// Note: no in-suite test drives a real IME composition. Synthetic
// `NSEvent.keyEvent(with:)` events carry baked `characters`, which an input
// method treats as already-translated text — composition never opens for
// them (the same reason HID injection with `keyboardSetUnicodeString`
// bypasses the IME). Composition, candidate placement and commit are
// verified in the launched app instead; see `docs/CONFORMANCE.md` §4.4.
