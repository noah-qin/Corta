import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// The direct translation must keep producing exact bytes, so this is tested
/// as a pure function from a synthetic `NSEvent` to a byte array. The M3.4
/// routing decision — which events ever reach this path versus the IME — is
/// covered in `TerminalViewIMETests`.
@MainActor
struct TerminalViewKeyEncodingTests {
    private static func keyEvent(
        characters: String, charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0,
        type: NSEvent.EventType = .keyDown, isRepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: isRepeat, keyCode: keyCode)!
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

    // MARK: - Kitty keyboard protocol (M6.9)

    /// The done-when for M6.9: a Neovim mapping that binds `Ctrl+I` and
    /// `Tab` differently cannot work while both are `0x09`.
    @Test func disambiguateSeparatesControlIFromTab() throws {
        func controlI() -> NSEvent {
            Self.keyEvent(
                characters: "\u{9}", charactersIgnoringModifiers: "i", modifiers: .control)
        }
        // Legacy: the two are the same byte, which is the problem.
        #expect(TerminalView.bytes(for: controlI()) == [0x09])
        #expect(TerminalView.bytes(for: Self.keyEvent(characters: "\t")) == [0x09])

        // With the flag, Ctrl+I is `CSI 105 ; 5 u` and Tab is untouched.
        #expect(
            TerminalView.bytes(for: controlI(), enhancements: .disambiguate)
                == Array("\u{1B}[105;5u".utf8))
        #expect(
            TerminalView.bytes(for: Self.keyEvent(characters: "\t"), enhancements: .disambiguate)
                == [0x09])
    }

    @Test func disambiguateSeparatesTheOtherThreeCollisions() throws {
        for (character, code) in [("m", 109), ("h", 104), ("[", 91)] {
            let event = Self.keyEvent(
                characters: "x", charactersIgnoringModifiers: character, modifiers: .control)
            #expect(
                TerminalView.bytes(for: event, enhancements: .disambiguate)
                    == Array("\u{1B}[\(code);5u".utf8))
        }
    }

    /// `disambiguate` asks a terminal to stop colliding keys, not to
    /// re-encode the keyboard. `Ctrl+A` has no unmodified twin, so `0x01`
    /// already says exactly one thing.
    @Test func disambiguateLeavesUnambiguousControlKeysAlone() throws {
        #expect(
            TerminalView.bytes(
                for: Self.keyEvent(
                    characters: "\u{1}", charactersIgnoringModifiers: "a", modifiers: .control),
                enhancements: .disambiguate) == [0x01])
        #expect(
            TerminalView.bytes(for: Self.keyEvent(characters: "a"), enhancements: .disambiguate)
                == Array("a".utf8))
    }

    @Test func disambiguateReportsTheModifierBitmask() throws {
        // 1 (base) + 1 (shift) + 4 (control).
        #expect(
            TerminalView.bytes(
                for: Self.keyEvent(
                    characters: "\u{9}", charactersIgnoringModifiers: "i",
                    modifiers: [.control, .shift]),
                enhancements: .disambiguate) == Array("\u{1B}[105;6u".utf8))
    }

    @Test func eventReportingDistinguishesPressRepeatAndRelease() throws {
        func controlI(type: NSEvent.EventType = .keyDown, repeat isRepeat: Bool = false) -> NSEvent {
            Self.keyEvent(
                characters: "\u{9}", charactersIgnoringModifiers: "i", modifiers: .control,
                type: type, isRepeat: isRepeat)
        }
        let enhancements: KeyboardEnhancementFlags = [.disambiguate, .reportEventTypes]
        #expect(
            TerminalView.bytes(for: controlI(), enhancements: enhancements)
                == Array("\u{1B}[105;5:1u".utf8))
        #expect(
            TerminalView.bytes(for: controlI(repeat: true), enhancements: enhancements)
                == Array("\u{1B}[105;5:2u".utf8))
        #expect(
            TerminalView.bytes(for: controlI(type: .keyUp), enhancements: enhancements)
                == Array("\u{1B}[105;5:3u".utf8))
    }

    @Test func eventReportingEncodesFunctionalKeyRelease() throws {
        let release = Self.keyEvent(
            characters: "\u{F700}", modifiers: [.numericPad, .function], keyCode: 126,
            type: .keyUp)
        #expect(
            TerminalView.bytes(for: release, enhancements: .reportEventTypes)
                == Array("\u{1B}[1;1:3A".utf8))
    }

    @Test func eventReportingDoesNotInventPlainTextReleases() throws {
        let release = Self.keyEvent(characters: "a", type: .keyUp)
        #expect(TerminalView.bytes(for: release, enhancements: .reportEventTypes) == nil)
    }
}
