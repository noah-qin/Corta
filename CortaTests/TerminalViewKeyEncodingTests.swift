import AppKit
import Testing

@testable import Corta

/// Keyboard events must produce bytes directly — never routed through
/// `interpretKeyEvents:` (`ROADMAP.md` M1.18) — so this is tested as a pure
/// function from a synthetic `NSEvent` to a byte array.
struct TerminalViewKeyEncodingTests {
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

    @Test func plainLetterSendsItsUTF8Bytes() throws {
        let event = Self.keyEvent(characters: "a")
        #expect(TerminalView.bytes(for: event) == Array("a".utf8))
    }

    @Test func returnSendsCarriageReturnNotLineFeed() throws {
        let event = Self.keyEvent(characters: "\r")
        #expect(TerminalView.bytes(for: event) == [0x0D])
    }

    @Test func controlCSendsETX() throws {
        let event = Self.keyEvent(characters: "\u{3}", charactersIgnoringModifiers: "c", modifiers: .control)
        #expect(TerminalView.bytes(for: event) == [0x03])
    }

    @Test func controlDSendsEOT() throws {
        let event = Self.keyEvent(characters: "\u{4}", charactersIgnoringModifiers: "d", modifiers: .control)
        #expect(TerminalView.bytes(for: event) == [0x04])
    }

    @Test func upArrowSendsCSIA() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
        #expect(TerminalView.bytes(for: event) == Array("\u{1B}[A".utf8))
    }

    @Test func nonASCIICharacterPassesThroughAsUTF8() throws {
        let event = Self.keyEvent(characters: "中")
        #expect(TerminalView.bytes(for: event) == Array("中".utf8))
    }

    @Test func commandUpArrowScrollsToTop() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
        guard case .toTop = TerminalView.scrollGesture(for: event) else {
            Issue.record("expected .toTop")
            return
        }
    }

    @Test func commandDownArrowScrollsToBottom() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        guard case .toBottom = TerminalView.scrollGesture(for: event) else {
            Issue.record("expected .toBottom")
            return
        }
    }

    @Test func plainArrowIsNotAScrollGesture() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
        #expect(TerminalView.scrollGesture(for: event) == nil)
    }
}
