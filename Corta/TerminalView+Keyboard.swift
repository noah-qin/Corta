import AppKit
import CortaTerminal

/// Keyboard input: one key event to the bytes a real terminal would send.
///
/// Routing (M3.4): an event carrying ⌘ or ⌃ bypasses the IME entirely —
/// control sequences are the terminal's own and must never reach an input
/// method. Every other event is offered to the input context first
/// (`inputContext.handleEvent(_:)`); only an event the IME does not consume
/// falls through to the direct `bytes(for:)` translation. Text an IME
/// commits does not come back through `keyDown` at all — it arrives via
/// `insertText(_:replacementRange:)` in `TerminalView+IME.swift`, which is
/// where it is written to the PTY. (`interpretKeyEvents:` is still never
/// called; it would swallow control keys the shell needs verbatim.)
extension TerminalView {
    override func keyDown(with event: NSEvent) {
        // U08: the shortcuts this method recognises itself come from the
        // binding table, never from a literal. AppKit dispatches a bound
        // keystroke through its menu item before `keyDown` ever runs, so
        // these branches normally do not fire at all — but a literal here
        // *did* fire the moment the menu stopped claiming the key, which is
        // exactly when the user had rebound or unbound the command.
        let bindings = keybindings?() ?? Keybindings()
        if onSearchKey?(event) == true {
            return
        }
        if let gesture = Self.scrollGesture(for: event, bindings: bindings) {
            onScroll?(gesture)
            return
        }
        if Self.isPasteShortcut(event, bindings: bindings) {
            onPaste?()
            return
        }
        // M3.4: offer the event to the IME first. A consumed event ends
        // here — the IME answers through `insertText`/`setMarkedText`.
        if Self.routesEventThroughIME(event), inputContext?.handleEvent(event) == true {
            return
        }
        deliverBytes(for: event)
    }

    override func keyUp(with event: NSEvent) {
        let enhancements = keyboardEnhancements?() ?? []
        guard enhancements.contains(.reportEventTypes),
            let bytes = Self.bytes(
                for: event, enhancements: enhancements, newLineMode: isNewLineMode?() ?? false,
                applicationCursorKeys: applicationCursorKeys?() ?? false,
                applicationKeypad: applicationKeypad?() ?? false,
                optionAsMeta: optionAsMeta?() ?? false)
        else {
            super.keyUp(with: event)
            return
        }
        onKeyBytes?(bytes)
    }

    /// The direct translation, run for events the IME never saw or declined.
    func deliverBytes(for event: NSEvent) {
        guard
            let bytes = Self.bytes(
                for: event, enhancements: keyboardEnhancements?() ?? [],
                newLineMode: isNewLineMode?() ?? false,
                applicationCursorKeys: applicationCursorKeys?() ?? false,
                applicationKeypad: applicationKeypad?() ?? false,
                optionAsMeta: optionAsMeta?() ?? false)
        else {
            super.keyDown(with: event)
            return
        }
        // The first link in the keypress-to-pixel chain
        // (`InputLatencySignposts`): everything from here to the GPU
        // completion handler is attributable in one trace.
        InputLatencySignposts.measure(.keyDown) { onKeyBytes?(bytes) }
    }

    /// M3.4: ⌘/⌃ events bypass the IME entirely. Kept a pure function of the
    /// event so the bypass decision is testable without a window server.
    static func routesEventThroughIME(_ event: NSEvent) -> Bool {
        event.modifierFlags.isDisjoint(with: [.command, .control])
    }

    /// The keystroke bound to Paste — checked before `bytes(for:)`, which
    /// would otherwise deliver a bare "v" to the child.
    ///
    /// Read from the bindings rather than written in as ⌘V (U08). The literal
    /// matched *any* combination containing ⌘ and "v", so `bind.paste =
    /// cmd+shift+v` left ⌘V pasting as well, and `bind.paste =` — an unbind,
    /// whose whole point is handing the key to the child — did not stop ⌘V
    /// pasting at all. Unbound now means unbound: the keystroke is encoded
    /// and sent to the child like any other key Corta does not claim.
    static func isPasteShortcut(_ event: NSEvent, bindings: Keybindings) -> Bool {
        bindings[.paste]?.matches(event) ?? false
    }

    /// The Edit menu's Paste item lands here; ⌘V arrives via `keyDown`.
    /// (`paste(_:)` comes from `NSStandardKeyBindingProviding`, so it is not
    /// an `NSResponder` override.)
    func paste(_ sender: Any?) {
        onPaste?()
    }

    /// Translates one key event directly to the bytes a real terminal would
    /// send. Control combinations map to C0 codes; arrows, the editing block
    /// and F1–F12 map to the xterm CSI/SS3 sequences `$TERM=xterm-256color`
    /// promises (`DESIGN.md` §2.5), with modifiers in xterm's `CSI 1 ; m X`
    /// form and DECCKM (`CSI ? 1 h`) switching the unmodified cursor keys
    /// and Home/End to their SS3 (application) forms.
    ///
    /// - Parameter enhancements: the kitty keyboard protocol flags the child
    ///   has asked for (M6.9). With `disambiguate` set, the keys the legacy
    ///   encoding collides are sent as `CSI code ; modifiers u` instead.
    /// - Parameter applicationKeypad: U04. DECKPAM (`ESC =`). When true the
    ///   numeric keypad sends its SS3 forms — `ESC O p`…`ESC O y` for the
    ///   digits, `ESC O M` for Enter — which is what a program that sent
    ///   `smkx` is waiting for.
    /// - Parameter optionAsMeta: U05. When true, ⌥ on a text or control key
    ///   sends an ESC prefix instead of the layout's alternate character —
    ///   what a PC keyboard's Alt does. Special keys are unaffected either
    ///   way: ⌥ already reaches the child there as the modifier parameter.
    static func bytes(
        for event: NSEvent, enhancements: KeyboardEnhancementFlags = [],
        newLineMode: Bool = false, applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false, optionAsMeta: Bool = false
    )
        -> [UInt8]?
    {
        let flags = event.modifierFlags
        let eventType = event.type == .keyUp ? 3 : (event.isARepeat ? 2 : 1)

        // A release has no representation unless the child asked for event
        // types. (Checked before the disambiguate path as well: a release
        // must never emit the press encoding of an ambiguous key.)
        if event.type == .keyUp, !enhancements.contains(.reportEventTypes) { return nil }

        if enhancements.contains(.reportEventTypes),
            let functional = eventTypedFunctionalBytes(for: event, eventType: eventType)
        {
            return functional
        }

        if enhancements.contains(.disambiguate),
            let disambiguated = disambiguatedBytes(
                for: event,
                eventType: enhancements.contains(.reportEventTypes) ? eventType : nil)
        {
            return disambiguated
        }

        // Text-producing keys remain legacy UTF-8 under reportEventTypes.
        // The protocol consequently has no release representation for them
        // unless reportAllKeysAsEscapeCodes is also enabled (not supported).
        if event.type == .keyUp { return nil }

        let modifiers = xtermModifiers(flags)

        if let special = event.specialKey {
            switch special {
            case .upArrow:
                return cursorKey("A", modifiers: modifiers, application: applicationCursorKeys)
            case .downArrow:
                return cursorKey("B", modifiers: modifiers, application: applicationCursorKeys)
            case .rightArrow:
                return cursorKey("C", modifiers: modifiers, application: applicationCursorKeys)
            case .leftArrow:
                return cursorKey("D", modifiers: modifiers, application: applicationCursorKeys)
            case .home:
                return cursorKey("H", modifiers: modifiers, application: applicationCursorKeys)
            case .end:
                return cursorKey("F", modifiers: modifiers, application: applicationCursorKeys)
            case .pageUp: return tildeKey(5, modifiers: modifiers)
            case .pageDown: return tildeKey(6, modifiers: modifiers)
            case .deleteForward: return tildeKey(3, modifiers: modifiers)
            case .f1: return functionKey("P", modifiers: modifiers)
            case .f2: return functionKey("Q", modifiers: modifiers)
            case .f3: return functionKey("R", modifiers: modifiers)
            case .f4: return functionKey("S", modifiers: modifiers)
            case .f5: return tildeKey(15, modifiers: modifiers)
            case .f6: return tildeKey(17, modifiers: modifiers)
            case .f7: return tildeKey(18, modifiers: modifiers)
            case .f8: return tildeKey(19, modifiers: modifiers)
            case .f9: return tildeKey(20, modifiers: modifiers)
            case .f10: return tildeKey(21, modifiers: modifiers)
            case .f11: return tildeKey(23, modifiers: modifiers)
            case .f12: return tildeKey(24, modifiers: modifiers)
            default: break
            }
        }

        // keyCode 48 is Tab on every layout; with Shift it is backtab
        // (`CSI Z`), which terminfo names kcbt and readline binds.
        if event.keyCode == 48, flags.contains(.shift) {
            return modifiers == 2
                ? Array("\u{1B}[Z".utf8)
                : Array("\u{1B}[1;\(modifiers)Z".utf8)
        }

        // U05 — ⌥ as Meta. ⌘ still belongs to the app, so it disqualifies
        // the combination; a special key never lands here (⌥ reaches the
        // child as the modifier parameter above).
        let meta: [UInt8] =
            optionAsMeta && flags.contains(.option) && !flags.contains(.command) ? [0x1B] : []

        // U04 — DECKPAM. The keypad's own SS3 forms, which only the keyCode
        // can identify: ⌤ reports "\u{3}" (indistinguishable from Ctrl+C at
        // that point) and every digit key reports the same character its
        // main-keyboard twin does. Modified keypad presses fall through to
        // the ordinary encoding rather than inventing a modified SS3 form —
        // xterm has none, and `xterm-256color`'s terminfo names none.
        if applicationKeypad, modifiers == 1,
            let final = keypadApplicationFinal(for: event.keyCode)
        {
            return meta + Array("\u{1B}O\(final)".utf8)
        }

        // The keypad's Enter (keyCode 76) reports "\u{3}" as its character,
        // which is indistinguishable from Ctrl+C at that point — keyCode is
        // the only honest source. Outside application keypad mode it sends
        // what Return sends.
        if event.keyCode == 76 {
            return meta + (newLineMode ? [0x0D, 0x0A] : [0x0D])
        }

        if flags.contains(.control), let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        {
            // Ctrl+letter -> C0 control code; the classic (scalar & 0x1F).
            let value = scalar.value
            if (0x40...0x7E).contains(value) {
                return meta + [UInt8(value & 0x1F)]
            }
        }

        // Under option-as-meta the base character comes from
        // `charactersIgnoringModifiers`, which keeps Shift but drops ⌥ — so
        // ⌥E (a dead key on the US layout) sends `ESC e` immediately rather
        // than waiting to compose. With meta off, `characters` carries the
        // layout's alternate character (é, ø, …) or dead-key result through
        // untouched, which is what international layouts need.
        let text = meta.isEmpty ? event.characters : event.charactersIgnoringModifiers
        guard let characters = text, !characters.isEmpty else { return nil }
        // Return sends CR, not LF — the pty's line discipline turns that
        // into whatever the child's terminal driver expects. Under LNM
        // (`CSI 20 h`) it sends CR LF instead, which is the half of that mode
        // the keyboard owns (ECMA-48 §8.3.106).
        if characters == "\r" || characters == "\n" {
            return meta + (newLineMode ? [0x0D, 0x0A] : [0x0D])
        }
        return meta + Array(characters.utf8)
    }

    /// The SS3 final byte for a keypad key under DECKPAM, by macOS virtual
    /// keycode (U04).
    ///
    /// The mapping is xterm's, which is the one `xterm-256color` promises:
    /// digits 0–9 are `p`…`y` in order, and the operators are the finals
    /// terminfo names as `kpADD`, `kpSUB` and friends. macOS has no Num Lock,
    /// so keyCode 71 is the Clear key that sits where PC keyboards put it,
    /// and it sends what xterm sends for `KP_Begin`'s neighbour rather than
    /// toggling anything.
    private static func keypadApplicationFinal(for keyCode: UInt16) -> Character? {
        switch keyCode {
        case 82: return "p"  // 0
        case 83: return "q"  // 1
        case 84: return "r"  // 2
        case 85: return "s"  // 3
        case 86: return "t"  // 4
        case 87: return "u"  // 5
        case 88: return "v"  // 6
        case 89: return "w"  // 7
        case 91: return "x"  // 8
        case 92: return "y"  // 9
        case 65: return "n"  // .
        case 67: return "j"  // *
        case 69: return "k"  // +
        case 78: return "m"  // -
        case 75: return "o"  // /
        case 81: return "X"  // =
        case 76: return "M"  // Enter
        default: return nil
        }
    }

    /// The kitty encoding, applied only to the keys the legacy one cannot
    /// tell apart (M6.9). Everything else keeps its legacy bytes: the
    /// `disambiguate` flag asks a terminal to stop colliding keys, not to
    /// re-encode the whole keyboard — that is what `reportAllKeysAsEscapeCodes`
    /// is for, and Corta does not claim it.
    ///
    /// The collisions, and why each matters:
    /// - `Ctrl+I` is `0x09`, which is also `Tab`.
    /// - `Ctrl+M` is `0x0D`, which is also `Return`.
    /// - `Ctrl+[` is `0x1B`, which is also `Esc` and the start of every
    ///   escape sequence.
    /// - `Ctrl+H` is `0x08`, which is also `Backspace` on many keyboards.
    private static func disambiguatedBytes(for event: NSEvent, eventType: Int?) -> [UInt8]? {
        let flags = event.modifierFlags
        guard flags.contains(.control), !flags.contains(.command),
            let characters = event.charactersIgnoringModifiers?.lowercased(),
            let scalar = characters.unicodeScalars.first
        else { return nil }
        // The four ambiguous ones only. `Ctrl+A` has no unmodified twin, so
        // `0x01` says exactly one thing and re-encoding it would break every
        // program that has read it for forty years.
        let ambiguous: Set<UInt32> = [
            UInt32(UnicodeScalar("i").value),
            UInt32(UnicodeScalar("m").value),
            UInt32(UnicodeScalar("h").value),
            UInt32(UnicodeScalar("[").value),
        ]
        guard ambiguous.contains(scalar.value) else { return nil }
        // `CSI unicode-key-code ; modifiers u`, modifiers as the protocol's
        // 1-based bitmask: shift 1, alt 2, ctrl 4, super 8.
        let modifiers = kittyModifiers(flags)
        let suffix = eventType.map { ":\($0)" } ?? ""
        return Array("\u{1B}[\(scalar.value);\(modifiers)\(suffix)u".utf8)
    }

    /// Event-reporting form for keys that already use an escape sequence.
    /// Enter, Tab and Backspace deliberately stay legacy unless the child
    /// also requests reportAllKeysAsEscapeCodes, per the kitty protocol.
    private static func eventTypedFunctionalBytes(for event: NSEvent, eventType: Int) -> [UInt8]? {
        let modifiers = kittyModifiers(event.modifierFlags)
        let parameter = "\(modifiers):\(eventType)"
        switch event.specialKey {
        case .some(.upArrow): return Array("\u{1B}[1;\(parameter)A".utf8)
        case .some(.downArrow): return Array("\u{1B}[1;\(parameter)B".utf8)
        case .some(.rightArrow): return Array("\u{1B}[1;\(parameter)C".utf8)
        case .some(.leftArrow): return Array("\u{1B}[1;\(parameter)D".utf8)
        case .some(.home): return Array("\u{1B}[1;\(parameter)H".utf8)
        case .some(.end): return Array("\u{1B}[1;\(parameter)F".utf8)
        case .some(.deleteForward): return Array("\u{1B}[3;\(parameter)~".utf8)
        case .some(.pageUp): return Array("\u{1B}[5;\(parameter)~".utf8)
        case .some(.pageDown): return Array("\u{1B}[6;\(parameter)~".utf8)
        case .some(.f1): return Array("\u{1B}[1;\(parameter)P".utf8)
        case .some(.f2): return Array("\u{1B}[1;\(parameter)Q".utf8)
        case .some(.f3): return Array("\u{1B}[1;\(parameter)R".utf8)
        case .some(.f4): return Array("\u{1B}[1;\(parameter)S".utf8)
        case .some(.f5): return Array("\u{1B}[15;\(parameter)~".utf8)
        case .some(.f6): return Array("\u{1B}[17;\(parameter)~".utf8)
        case .some(.f7): return Array("\u{1B}[18;\(parameter)~".utf8)
        case .some(.f8): return Array("\u{1B}[19;\(parameter)~".utf8)
        case .some(.f9): return Array("\u{1B}[20;\(parameter)~".utf8)
        case .some(.f10): return Array("\u{1B}[21;\(parameter)~".utf8)
        case .some(.f11): return Array("\u{1B}[23;\(parameter)~".utf8)
        case .some(.f12): return Array("\u{1B}[24;\(parameter)~".utf8)
        default: return nil
        }
    }

    /// Cursor keys and Home/End. DECCKM (`CSI ? 1 h`) switches the
    /// unmodified forms from CSI to SS3; the modified form is xterm's
    /// `CSI 1 ; m X` in both modes, which is what xterm does and what
    /// `xterm-256color`'s terminfo entry (kUP3 and friends) names.
    private static func cursorKey(
        _ final: Character, modifiers: Int, application: Bool
    ) -> [UInt8] {
        if modifiers != 1 {
            return Array("\u{1B}[1;\(modifiers)\(final)".utf8)
        }
        return application ? Array("\u{1B}O\(final)".utf8) : Array("\u{1B}[\(final)".utf8)
    }

    /// F1–F4: SS3 unmodified, `CSI 1 ; m X` with modifiers (xterm's form).
    private static func functionKey(_ final: Character, modifiers: Int) -> [UInt8] {
        modifiers == 1
            ? Array("\u{1B}O\(final)".utf8)
            : Array("\u{1B}[1;\(modifiers)\(final)".utf8)
    }

    /// The `CSI number ~` family: Delete, Page Up/Down and F5–F12.
    private static func tildeKey(_ number: Int, modifiers: Int) -> [UInt8] {
        modifiers == 1
            ? Array("\u{1B}[\(number)~".utf8)
            : Array("\u{1B}[\(number);\(modifiers)~".utf8)
    }

    /// xterm's 1-based modifier bitmask for the legacy encoding: shift 1,
    /// alt 2, ctrl 4, meta 8. Caps Lock is kitty-only and stays out — xterm
    /// has no value for it.
    private static func xtermModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 1
        if flags.contains(.shift) { modifiers += 1 }
        if flags.contains(.option) { modifiers += 2 }
        if flags.contains(.control) { modifiers += 4 }
        if flags.contains(.command) { modifiers += 8 }
        return modifiers
    }

    private static func kittyModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 1
        if flags.contains(.shift) { modifiers += 1 }
        if flags.contains(.option) { modifiers += 2 }
        if flags.contains(.control) { modifiers += 4 }
        if flags.contains(.command) { modifiers += 8 }
        if flags.contains(.capsLock) { modifiers += 64 }
        return modifiers
    }
}
