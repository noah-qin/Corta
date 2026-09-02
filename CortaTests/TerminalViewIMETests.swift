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
        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!)
        guard case .some(.toTop) = scrolled else {
            Issue.record("expected .toTop")
            return
        }
        #expect(bytes.isEmpty)
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
