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

/// Keyboard input: one key event to the bytes a real terminal would send.
///
/// ⌘ and ⌃ events bypass the IME; everything else is offered to the input
/// context first, and only what it declines reaches `bytes(for:)`. IME
/// commits arrive via `insertText` (`TerminalView+IME.swift`), and
/// `interpretKeyEvents:` is never called: it swallows control keys.
extension TerminalView {
    override func keyDown(with event: NSEvent) {
        // From the bindings, never a literal: a literal fired exactly when the
        // menu stopped claiming the key, i.e. after a rebind or unbind.
        let bindings = keybindings?() ?? Keybindings()
        if onCompletionKey?(event) == true { return }
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
        // A consumed event ends here; the IME answers via `insertText`.
        if Self.routesEventThroughIME(
            event, optionAsMeta: optionAsMeta?() ?? false, composing: hasMarkedText()),
            inputContext?.handleEvent(event) == true
        {
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

    /// The direct translation, for events the IME never saw or declined.
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
        // Starts the keypress-to-pixel trace (`InputLatencySignposts`).
        noteKeystrokeForMetrics(at: event.timestamp)
        InputLatencySignposts.measure(.keyDown) { onKeyBytes?(bytes) }
    }

    /// ⌘/⌃ bypass the IME, and so does ⌥ under `option-as-meta` — otherwise
    /// macOS composes ⌥F into `ƒ`. With the setting off ⌥ stays text input,
    /// which dead keys and international layouts need.
    ///
    /// A terminal key (`isTerminalKey`) bypasses it too unless a composition
    /// is open. The input context consumes every such key — any input source,
    /// ABC included — and hands it back as a text-editing command
    /// (`moveWordLeft:`, `scrollToBeginningOfDocument:`, `deleteForward:`,
    /// `complete:` for F5, …) that a terminal has no use for: ⌥←, Home, End,
    /// Page Up/Down, forward delete, F1–F12 and the shifted arrows reached
    /// the child as nothing, and the plain arrows lost DECCKM. While
    /// composing, the IME needs them to move through and commit candidates.
    /// Pure, for tests.
    static func routesEventThroughIME(
        _ event: NSEvent, optionAsMeta: Bool = false, composing: Bool = false
    ) -> Bool {
        if !composing, isTerminalKey(event) { return false }
        if optionAsMeta, event.modifierFlags.contains(.option) { return false }
        return event.modifierFlags.isDisjoint(with: [.command, .control])
    }

    /// The keys `bytes(for:)` encodes as a terminal does rather than as text:
    /// Return, Tab, Delete, Escape, keypad Enter, the arrows, the editing
    /// block and the function keys. By key code, which names the physical key
    /// whatever the input source.
    static func isTerminalKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 48, 51, 53, 76,  // Return, Tab, Delete, Escape, keypad Enter
            115, 116, 117, 119, 121,  // Home, Page Up, forward delete, End, Page Down
            123, 124, 125, 126,  // the arrows
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111:  // F1–F12
            return true
        default:
            return false
        }
    }

    /// The keystroke bound to Paste, checked before `bytes(for:)`. From the
    /// bindings, so an unbind really hands ⌘V to the child.
    static func isPasteShortcut(_ event: NSEvent, bindings: Keybindings) -> Bool {
        bindings[.paste]?.matches(event) ?? false
    }

    /// The Edit menu's Paste; ⌘V arrives via `keyDown`. From
    /// `NSStandardKeyBindingProviding`, not an `NSResponder` override.
    func paste(_ sender: Any?) {
        onPaste?()
    }

    /// Translates one key event to bytes: C0 for control combinations, and
    /// the xterm CSI/SS3 forms `xterm-256color` promises (D08) for arrows, the
    /// editing block and F1–F12, with modifiers as `CSI 1 ; m X` and DECCKM
    /// selecting SS3 for unmodified cursor keys and Home/End.
    ///
    /// - Parameter enhancements: kitty flags; `disambiguate` sends colliding
    ///   keys as `CSI code ; modifiers u`.
    /// - Parameter applicationKeypad: DECKPAM (`ESC =`): the keypad sends
    ///   `ESC O p`…`ESC O y` and `ESC O M`, as `smkx` programs expect.
    /// - Parameter optionAsMeta: ⌥ on a text or control key sends an ESC
    ///   prefix; special keys carry ⌥ as the modifier parameter either way.
    static func bytes(
        for event: NSEvent, enhancements: KeyboardEnhancementFlags = [],
        newLineMode: Bool = false, applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false, optionAsMeta: Bool = false
    )
        -> [UInt8]?
    {
        let flags = event.modifierFlags
        let eventType = event.type == .keyUp ? 3 : (event.isARepeat ? 2 : 1)

        // No release encoding unless event types were requested — checked
        // before disambiguation so a release never sends the press encoding.
        if event.type == .keyUp, !enhancements.contains(.reportEventTypes) { return nil }

        if enhancements.contains(.reportEventTypes),
            let functional = eventTypedFunctionalBytes(for: event, eventType: eventType)
        {
            return functional
        }

        if enhancements.contains(.disambiguate),
            let disambiguated = disambiguatedBytes(
                for: event,
                eventType: enhancements.contains(.reportEventTypes) ? eventType : nil,
                optionAsMeta: optionAsMeta)
        {
            return disambiguated
        }

        // Text keys stay legacy UTF-8, with no release form without
        // reportAllKeysAsEscapeCodes (unsupported).
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

        // Shift-Tab is backtab (`CSI Z`, terminfo kcbt).
        if event.keyCode == 48, flags.contains(.shift) {
            return modifiers == 2
                ? Array("\u{1B}[Z".utf8)
                : Array("\u{1B}[1;\(modifiers)Z".utf8)
        }

        // ⌥ as Meta; ⌘ belongs to the app and disqualifies it.
        let meta: [UInt8] =
            optionAsMeta && flags.contains(.option) && !flags.contains(.command) ? [0x1B] : []

        // ⌥⌫ deletes a word: `ESC DEL`, the meta form shells bind to
        // backward-kill-word, whether or not ⌥ is Meta — on Delete ⌥ composes
        // nothing, and plain DEL would erase one character instead.
        if event.keyCode == 51, flags.contains(.option), !flags.contains(.command),
            !flags.contains(.control)
        {
            return [0x1B, 0x7F]
        }

        // DECKPAM, by keyCode: ⌤ reports "\u{3}" like Ctrl+C, and keypad digits
        // match the main row. Modified keypad keys use the ordinary encoding;
        // xterm has no modified SS3 form.
        if applicationKeypad, modifiers == 1,
            let final = keypadApplicationFinal(for: event.keyCode)
        {
            return meta + Array("\u{1B}O\(final)".utf8)
        }

        // Keypad Enter reports "\u{3}" (like Ctrl+C); outside DECKPAM it is
        // Return.
        if event.keyCode == 76 {
            return meta + (newLineMode ? [0x0D, 0x0A] : [0x0D])
        }

        if flags.contains(.control), let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        {
            // Ctrl+letter -> C0 (scalar & 0x1F).
            let value = scalar.value
            if (0x40...0x7E).contains(value) {
                return meta + [UInt8(value & 0x1F)]
            }
        }

        // Meta uses `charactersIgnoringModifiers` (Shift kept, ⌥ dropped), so ⌥E
        // sends `ESC e` instead of starting a dead key; without meta the
        // composed character passes through.
        let text = meta.isEmpty ? event.characters : event.charactersIgnoringModifiers
        guard let characters = text, !characters.isEmpty else { return nil }
        // Return sends CR, or CR LF under LNM (ECMA-48 §8.3.106).
        if characters == "\r" || characters == "\n" {
            return meta + (newLineMode ? [0x0D, 0x0A] : [0x0D])
        }
        return meta + Array(characters.utf8)
    }

    /// DECKPAM's SS3 final for a keypad keycode, as xterm maps it: digits
    /// `p`…`y`, operators per terminfo `kpADD` and friends. Keycode 71 is the
    /// Mac's Clear key (no Num Lock).
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

    /// The kitty encoding for only the keys legacy encoding collides —
    /// `disambiguate` doesn't re-encode the keyboard
    /// (`reportAllKeysAsEscapeCodes`, unclaimed, would). The collisions:
    /// Ctrl+I/Tab (0x09), Ctrl+M/Return (0x0D), Ctrl+[/Esc (0x1B),
    /// Ctrl+H/Backspace (0x08); Escape itself, which legacy encoding cannot
    /// tell from the start of an Alt sequence (`CSI 27 u`); and ⌥ as Meta on
    /// a text key, whose `ESC` prefix reads as Escape then the key.
    private static func disambiguatedBytes(
        for event: NSEvent, eventType: Int?, optionAsMeta: Bool
    ) -> [UInt8]? {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return nil }
        let modifiers = kittyModifiers(flags)
        func encoded(_ code: UInt32, modifiers: Int) -> [UInt8] {
            // `CSI code u` when there is nothing to add, as the spec writes it.
            if modifiers == 1, eventType == nil || eventType == 1 {
                return Array("\u{1B}[\(code)u".utf8)
            }
            let suffix = eventType.map { ":\($0)" } ?? ""
            return Array("\u{1B}[\(code);\(modifiers)\(suffix)u".utf8)
        }
        if event.keyCode == 53 {
            return encoded(27, modifiers: modifiers)
        }
        // ⌥⌫: a modified Backspace, which the spec encodes (only the plain
        // key stays legacy).
        if event.keyCode == 51, flags.contains(.option), !flags.contains(.control) {
            return encoded(127, modifiers: modifiers)
        }
        if optionAsMeta, flags.contains(.option), !flags.contains(.control),
            !isTerminalKey(event),
            let base = event.characters(byApplyingModifiers: [])?.lowercased().unicodeScalars.first,
            (0x20...0x7E).contains(base.value)
        {
            return encoded(base.value, modifiers: modifiers)
        }
        guard flags.contains(.control),
            let characters = event.charactersIgnoringModifiers?.lowercased(),
            let scalar = characters.unicodeScalars.first
        else { return nil }
        // Only these four: `0x01` and friends are unambiguous.
        let ambiguous: Set<UInt32> = [
            UInt32(UnicodeScalar("i").value),
            UInt32(UnicodeScalar("m").value),
            UInt32(UnicodeScalar("h").value),
            UInt32(UnicodeScalar("[").value),
        ]
        guard ambiguous.contains(scalar.value) else { return nil }
        // `CSI code ; modifiers u`, bitmask shift 1, alt 2, ctrl 4, super 8.
        let suffix = eventType.map { ":\($0)" } ?? ""
        return Array("\u{1B}[\(scalar.value);\(modifiers)\(suffix)u".utf8)
    }

    /// Event-reporting form for keys already sent as escape sequences. Enter,
    /// Tab and Backspace stay legacy without reportAllKeysAsEscapeCodes.
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

    /// Cursor keys and Home/End: DECCKM picks SS3 for the unmodified form;
    /// modified is `CSI 1 ; m X` in both modes (terminfo kUP3 and friends).
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

    /// xterm's 1-based bitmask: shift 1, alt 2, ctrl 4, meta 8. Caps Lock is
    /// kitty-only.
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
