import AppKit
import Testing

@testable import Corta

/// M3.1–M3.4: IME routing and marked-text handling. Everything here runs
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

    private static func makeView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.cellSize = CGSize(width: 8, height: 17)
        return view
    }

    // MARK: - M3.4 routing

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

    @Test func unhandledKeyFallsThroughToDirectBytes() {
        // No window, no input context — the IME path declines and keyDown
        // behaves exactly as the pre-M3 direct path did.
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
        // Command's, and no longer scrolls here (U08).
        view.keyDown(with: Self.shiftHome())
        guard case .some(.toTop) = scrolled else {
            Issue.record("expected .toTop")
            return
        }
        #expect(bytes.isEmpty)
    }

    /// U08 — an unbound command hands its key to the child. With `bind.paste`
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
        // context first (M3.4). The bytes it ends up sending are pinned in
        // `TerminalViewKeyEncodingTests`; what matters here is that the
        // gesture no longer intercepts it.
        view.keyDown(with: Self.shiftHome())
        #expect(scrolled == nil)
    }

    private static func shiftHome() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F729}",
            charactersIgnoringModifiers: "\u{F729}", isARepeat: false, keyCode: 115)!
    }

    // MARK: - M3.1 marked text / commit

    @Test func markedTextNeverReachesThePTY() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 5))
        #expect(bytes.isEmpty)
    }

    @Test func committedTextIsWrittenAsUTF8AndClearsThePreedit() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.setMarkedText(
            "zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bytes == Array("中".utf8))
        #expect(!view.hasMarkedText())
        #expect(view.markedRange().location == NSNotFound)
    }

    @Test func insertTextAcceptsAttributedStrings() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.insertText(
            NSAttributedString(string: "中文"), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bytes == Array("中文".utf8))
    }

    @Test func emptyMarkedTextAndUnmarkBothClearThePreedit() {
        let view = Self.makeView()
        view.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.setMarkedText(
            "", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        view.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(!view.hasMarkedText())
    }

    @Test func doCommandForwardsTheKeysAnIMEConsumed() {
        let view = Self.makeView()
        var bytes: [UInt8] = []
        view.onKeyBytes = { bytes += $0 }
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(bytes == [0x0D, 0x7F, 0x1B] + Array("\u{1B}[A\u{1B}[B\u{1B}[D\u{1B}[C".utf8))
    }

    // MARK: - M3.3 preedit overlay

    @Test func preeditOverlayAppearsAtTheCursorCell() {
        let view = Self.makeView()
        let cell = CGRect(x: 40, y: 17, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        view.setMarkedText(
            "zh", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first else {
            Issue.record("no preedit overlay was added")
            return
        }
        #expect(!overlay.isHidden)
        #expect(overlay.frame.origin == cell.origin)
        #expect(overlay.frame.width >= cell.width)
    }

    /// Found by looking at a light-appearance window: the preedit was drawn
    /// in near-white on a light background and could not be read. The overlay
    /// held its own copy of "the colour the renderer uses", which stopped
    /// being true once the palette started following the theme and the system
    /// appearance.
    @Test func preeditTakesItsColourFromTheLivePalette() {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        let saved = TerminalColorPalette.activeVariant
        defer { TerminalColorPalette.apply(saved) }

        func drawnColour(underForeground foreground: SIMD4<Float>) -> NSColor? {
            var variant = saved
            variant.foreground = foreground
            TerminalColorPalette.apply(variant)
            view.setMarkedText(
                "ni", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first,
                let drawn = overlay.markedText
            else { return nil }
            return drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }

        let onDark = try? #require(drawnColour(underForeground: SIMD4<Float>(0.95, 0.95, 0.95, 1)))
        let onLight = try? #require(drawnColour(underForeground: SIMD4<Float>(0.1, 0.1, 0.1, 1)))
        #expect(onDark?.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.9)
        #expect(onLight?.usingColorSpace(.sRGB)?.redComponent ?? 1 < 0.2)
    }

    @Test func preeditOverlayKeepsTheIMEUnderlineStyling() {
        let view = Self.makeView()
        view.cursorRectProvider = { CGRect(x: 0, y: 0, width: 8, height: 17) }
        let marked = NSAttributedString(
            string: "中文",
            attributes: [.underlineStyle: NSUnderlineStyle.thick.rawValue])
        view.setMarkedText(
            marked, selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let overlay = view.subviews.compactMap({ $0 as? MarkedTextOverlayView }).first,
            let drawn = overlay.markedText
        else {
            Issue.record("no preedit overlay was added")
            return
        }
        let underline = drawn.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.thick.rawValue)
        // Display-only defaults are filled in where the IME set nothing.
        #expect(drawn.attribute(.font, at: 0, effectiveRange: nil) != nil)
        #expect(drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
    }

    // MARK: - M3.2 candidate window placement

    /// `NSView.inputContext` is documented to return nil unless the receiver
    /// conforms to `NSTextInputClient` — this pins that the conformance
    /// actually engages AppKit's input machinery, the precondition for every
    /// IME behaviour above.
    @Test func inputContextEngagesWhenFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        #expect(view.inputContext != nil)
    }

    @Test func firstRectIsTheCursorCellInScreenCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = Self.makeView()
        window.contentView?.addSubview(view)
        let cell = CGRect(x: 16, y: 34, width: 8, height: 17)
        view.cursorRectProvider = { cell }
        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(rect == window.convertToScreen(view.convert(cell, to: nil)))
        #expect(rect.size == cell.size)
        #expect(rect != .zero)
    }

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

    // MARK: - U02 audit: splits, resize and focus changes

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
    /// its business, and an earlier version of this test asserting a
    /// hard-coded +100 was asserting AppKit's choice instead of Corta's
    /// behaviour.
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
    /// overlay used to keep a second copy of the cell size in a stored
    /// property as well; nothing ever read it, and sizing came from the rect
    /// all along, so the copy is gone rather than made to agree (U02).
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

// Note: no in-suite test drives a real IME composition. Synthetic
// `NSEvent.keyEvent(with:)` events carry baked `characters`, which an input
// method treats as already-translated text — composition never opens for
// them (the same reason HID injection with `keyboardSetUnicodeString`
// bypasses the IME). Composition, candidate placement and commit are
// verified in the launched app instead; see `docs/CONFORMANCE.md` §4.4.
