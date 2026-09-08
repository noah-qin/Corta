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

    private static func functionKeyEvent(
        _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: modifiers.union([.numericPad, .function]), timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
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

    /// ⇧Home / ⇧End are what `scroll-to-top` and `scroll-to-bottom` are bound
    /// to (`CONFIGURATION.md` §5), and the gesture follows the binding.
    @Test func shiftHomeAndShiftEndAreTheScrollGestures() throws {
        let bindings = Keybindings()
        guard case .toTop = TerminalView.scrollGesture(
            for: Self.functionKeyEvent("\u{F729}", keyCode: 115, modifiers: .shift),
            bindings: bindings)
        else {
            Issue.record("expected .toTop")
            return
        }
        guard case .toBottom = TerminalView.scrollGesture(
            for: Self.functionKeyEvent("\u{F72B}", keyCode: 119, modifiers: .shift),
            bindings: bindings)
        else {
            Issue.record("expected .toBottom")
            return
        }
    }

    /// U08 — the ghost binding. ⌘↑ belongs to `previous-command`; the literal
    /// this branch used to carry made it scroll to the top of the scrollback
    /// the moment that command was unbound.
    @Test func commandArrowsAreNoLongerScrollGestures() throws {
        let bindings = Keybindings()
        #expect(
            TerminalView.scrollGesture(
                for: Self.functionKeyEvent("\u{F700}", keyCode: 126, modifiers: .command),
                bindings: bindings) == nil)
        #expect(
            TerminalView.scrollGesture(
                for: Self.functionKeyEvent("\u{F701}", keyCode: 125, modifiers: .command),
                bindings: bindings) == nil)
    }

    @Test func plainArrowIsNotAScrollGesture() throws {
        let event = Self.functionKeyEvent("\u{F700}", keyCode: 126)
        #expect(TerminalView.scrollGesture(for: event, bindings: Keybindings()) == nil)
    }

    /// Rebinding moves the gesture with it, and unbinding removes it — the
    /// unbound keystroke then encodes as an ordinary key for the child.
    @Test func theScrollGestureFollowsARebindAndAnUnbind() throws {
        let rebound = Configuration.parse("bind.scroll-to-top = ctrl+alt+up").0.keybindings
        let controlAltUp = Self.functionKeyEvent(
            "\u{F700}", keyCode: 126, modifiers: [.control, .option])
        let shiftHome = Self.functionKeyEvent("\u{F729}", keyCode: 115, modifiers: .shift)
        guard case .toTop = TerminalView.scrollGesture(for: controlAltUp, bindings: rebound) else {
            Issue.record("expected .toTop from the rebound key")
            return
        }
        #expect(TerminalView.scrollGesture(for: shiftHome, bindings: rebound) == nil)

        let unbound = Configuration.parse("bind.scroll-to-top = ").0.keybindings
        #expect(TerminalView.scrollGesture(for: shiftHome, bindings: unbound) == nil)
        #expect(TerminalView.bytes(for: shiftHome) == Array("\u{1B}[1;2H".utf8))
    }

    // MARK: - Paste (U08)

    /// The paste interception is the binding, not a written-in ⌘V.
    @Test func pasteInterceptionFollowsTheBinding() throws {
        let commandV = Self.keyEvent(characters: "v", modifiers: .command, keyCode: 9)
        let commandShiftV = Self.keyEvent(
            characters: "V", charactersIgnoringModifiers: "V", modifiers: [.command, .shift],
            keyCode: 9)
        #expect(TerminalView.isPasteShortcut(commandV, bindings: Keybindings()))
        #expect(!TerminalView.isPasteShortcut(commandShiftV, bindings: Keybindings()))

        let rebound = Configuration.parse("bind.paste = cmd+shift+v").0.keybindings
        #expect(!TerminalView.isPasteShortcut(commandV, bindings: rebound))
        #expect(TerminalView.isPasteShortcut(commandShiftV, bindings: rebound))

        // Unbound is unbound: the key goes to the child like any other.
        let unbound = Configuration.parse("bind.paste = ").0.keybindings
        #expect(!TerminalView.isPasteShortcut(commandV, bindings: unbound))
        #expect(!TerminalView.isPasteShortcut(commandShiftV, bindings: unbound))
        #expect(TerminalView.bytes(for: commandV) == Array("v".utf8))
    }

    // MARK: - International layouts and dead keys (U05)

    /// **What `option-as-meta` has to not break.** On macOS ⌥ is text input:
    /// on a US layout ⌥e begins a dead-key acute accent, and on a German
    /// layout ⌥5 is `[`. The two modes read *different* fields of the event
    /// — `characters` with the setting off, `charactersIgnoringModifiers`
    /// with it on — and that is the whole compatibility argument, so it is
    /// asserted on the events those layouts actually produce rather than
    /// argued from the code.
    @Test func optionOffKeepsTheLayoutsAlternateCharacter() {
        // German layout: ⌥5 produces "[" while the unmodified key is "5".
        let bracket = Self.keyEvent(characters: "[", charactersIgnoringModifiers: "5",
            modifiers: .option, keyCode: 23)
        #expect(TerminalView.bytes(for: bracket) == Array("[".utf8))

        // A dead key mid-compose: the IME path aside, an ⌥e that produced no
        // character yet sends nothing rather than a stray "e".
        let deadKey = Self.keyEvent(
            characters: "", charactersIgnoringModifiers: "e", modifiers: .option, keyCode: 14)
        #expect(TerminalView.bytes(for: deadKey) == nil)

        // The composed result arrives as an ordinary character event.
        let composed = Self.keyEvent(characters: "é", charactersIgnoringModifiers: "e", keyCode: 14)
        #expect(TerminalView.bytes(for: composed) == Array("é".utf8))

        // Scandinavian layouts put ø on ⌥o.
        let slashedO = Self.keyEvent(
            characters: "ø", charactersIgnoringModifiers: "o", modifiers: .option, keyCode: 31)
        #expect(TerminalView.bytes(for: slashedO) == Array("ø".utf8))
    }

    /// With the setting on, the *base* character is what is sent after ESC —
    /// so ⌥e is `ESC e` immediately instead of waiting to compose, which is
    /// what a program binding `M-e` is waiting for. The layout's alternate
    /// character is deliberately given up; that is the trade the setting
    /// exists to make, and it is off by default because most people want the
    /// character.
    @Test func optionAsMetaSendsTheBaseCharacter() {
        let deadKey = Self.keyEvent(
            characters: "", charactersIgnoringModifiers: "e", modifiers: .option, keyCode: 14)
        #expect(
            TerminalView.bytes(for: deadKey, optionAsMeta: true) == Array("\u{1B}e".utf8))

        let bracket = Self.keyEvent(
            characters: "[", charactersIgnoringModifiers: "5", modifiers: .option, keyCode: 23)
        #expect(
            TerminalView.bytes(for: bracket, optionAsMeta: true) == Array("\u{1B}5".utf8))

        // Shift survives, because `charactersIgnoringModifiers` keeps it.
        let shifted = Self.keyEvent(
            characters: "Ø", charactersIgnoringModifiers: "O", modifiers: [.option, .shift],
            keyCode: 31)
        #expect(
            TerminalView.bytes(for: shifted, optionAsMeta: true) == Array("\u{1B}O".utf8))
    }

    /// ⌘ disqualifies the combination in both modes: the app's own shortcuts
    /// keep their key, and no ESC prefix is invented for them.
    ///
    /// The event is the one macOS actually delivers — with ⌘ held it does not
    /// compose the layout's alternate character, so `characters` is the base
    /// letter rather than `π`.
    @Test func commandIsNeverMeta() {
        let event = Self.keyEvent(
            characters: "p", charactersIgnoringModifiers: "p", modifiers: [.option, .command],
            keyCode: 35)
        let bytes = TerminalView.bytes(for: event, optionAsMeta: true)
        #expect(bytes == Array("p".utf8))
        #expect(bytes?.first != 0x1B, "no ESC prefix belongs on a ⌘ combination")
    }

    /// A special key is unaffected either way — ⌥ already reaches the child
    /// there as the xterm modifier parameter, so neither mode may add an ESC.
    @Test func specialKeysAreUnaffectedByMeta() {
        let optionLeft = Self.functionKeyEvent("\u{F702}", keyCode: 123, modifiers: .option)
        let expected = Array("\u{1B}[1;3D".utf8)
        #expect(TerminalView.bytes(for: optionLeft) == expected)
        #expect(TerminalView.bytes(for: optionLeft, optionAsMeta: true) == expected)
    }

    // MARK: - The keypad (U04)

    private static func keypadEvent(_ keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    /// Without DECKPAM the keypad is the keys printed on it — a `7` is a
    /// `7`, and ⌤ is Return.
    @Test func theKeypadSendsItsPrintedKeysByDefault() {
        #expect(TerminalView.bytes(for: Self.keypadEvent(89, characters: "7")) == Array("7".utf8))
        #expect(TerminalView.bytes(for: Self.keypadEvent(69, characters: "+")) == Array("+".utf8))
        #expect(TerminalView.bytes(for: Self.keypadEvent(76, characters: "\u{3}")) == [0x0D])
    }

    /// `ESC =` (DECKPAM) switches it to the SS3 forms xterm sends and
    /// `xterm-256color` promises. A program that sent `smkx` is waiting for
    /// exactly these; the digits were reaching it as plain text before U04.
    @Test func applicationKeypadSendsSS3Forms() {
        func bytes(_ keyCode: UInt16, _ characters: String) -> [UInt8]? {
            TerminalView.bytes(
                for: Self.keypadEvent(keyCode, characters: characters), applicationKeypad: true)
        }
        #expect(bytes(82, "0") == Array("\u{1B}Op".utf8))
        #expect(bytes(89, "7") == Array("\u{1B}Ow".utf8))
        #expect(bytes(92, "9") == Array("\u{1B}Oy".utf8))
        #expect(bytes(65, ".") == Array("\u{1B}On".utf8))
        #expect(bytes(69, "+") == Array("\u{1B}Ok".utf8))
        #expect(bytes(78, "-") == Array("\u{1B}Om".utf8))
        #expect(bytes(67, "*") == Array("\u{1B}Oj".utf8))
        #expect(bytes(75, "/") == Array("\u{1B}Oo".utf8))
        // ⌤ reports "\u{3}", indistinguishable from Ctrl+C by character.
        #expect(bytes(76, "\u{3}") == Array("\u{1B}OM".utf8))
    }

    /// The main keyboard is untouched by DECKPAM — only the keypad's own
    /// virtual keycodes are remapped, and a `7` typed on the top row stays a
    /// `7`.
    @Test func applicationKeypadLeavesTheMainKeyboardAlone() {
        let topRowSeven = Self.keyEvent(characters: "7", keyCode: 26)
        #expect(
            TerminalView.bytes(for: topRowSeven, applicationKeypad: true) == Array("7".utf8))
    }

    /// A modified keypad press has no SS3 form in xterm and none in
    /// `xterm-256color`'s terminfo, so it falls through to the ordinary
    /// encoding rather than to an invented one.
    @Test func modifiedKeypadPressesUseTheOrdinaryEncoding() {
        let controlKeypadFour = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.control, .numericPad, .function], timestamp: 0, windowNumber: 0,
            context: nil, characters: "4", charactersIgnoringModifiers: "4", isARepeat: false,
            keyCode: 86)!
        #expect(
            TerminalView.bytes(for: controlKeypadFour, applicationKeypad: true)
                == Array("4".utf8))
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
