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
        if onSearchKey?(event) == true {
            return
        }
        if let gesture = Self.scrollGesture(for: event) {
            onScroll?(gesture)
            return
        }
        if Self.isPasteShortcut(event) {
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
            let bytes = Self.bytes(for: event, enhancements: enhancements)
        else {
            super.keyUp(with: event)
            return
        }
        onKeyBytes?(bytes)
    }

    /// The direct translation, run for events the IME never saw or declined.
    func deliverBytes(for event: NSEvent) {
        guard let bytes = Self.bytes(for: event, enhancements: keyboardEnhancements?() ?? []) else {
            super.keyDown(with: event)
            return
        }
        onKeyBytes?(bytes)
    }

    /// M3.4: ⌘/⌃ events bypass the IME entirely. Kept a pure function of the
    /// event so the bypass decision is testable without a window server.
    static func routesEventThroughIME(_ event: NSEvent) -> Bool {
        event.modifierFlags.isDisjoint(with: [.command, .control])
    }

    /// ⌘V — checked before `bytes(for:)`, which would otherwise deliver a
    /// bare "v" to the child.
    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// The Edit menu's Paste item lands here; ⌘V arrives via `keyDown`.
    /// (`paste(_:)` comes from `NSStandardKeyBindingProviding`, so it is not
    /// an `NSResponder` override.)
    func paste(_ sender: Any?) {
        onPaste?()
    }

    /// Translates one key event directly to the bytes a real terminal would
    /// send. Control combinations map to C0 codes; arrows and a handful of
    /// editing keys map to the xterm CSI sequences `$TERM=xterm-256color`
    /// promises (`DESIGN.md` §2.5).
    ///
    /// - Parameter enhancements: the kitty keyboard protocol flags the child
    ///   has asked for (M6.9). With `disambiguate` set, the keys the legacy
    ///   encoding collides are sent as `CSI code ; modifiers u` instead.
    static func bytes(for event: NSEvent, enhancements: KeyboardEnhancementFlags = [])
        -> [UInt8]?
    {
        let flags = event.modifierFlags
        let eventType = event.type == .keyUp ? 3 : (event.isARepeat ? 2 : 1)

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

        switch event.specialKey {
        case .some(.upArrow): return escape("A")
        case .some(.downArrow): return escape("B")
        case .some(.rightArrow): return escape("C")
        case .some(.leftArrow): return escape("D")
        case .some(.home): return escape("H")
        case .some(.end): return escape("F")
        case .some(.deleteForward): return [0x1B, 0x5B, 0x33, 0x7E]  // ESC [ 3 ~
        default: break
        }

        if flags.contains(.control), let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first
        {
            // Ctrl+letter -> C0 control code; the classic (scalar & 0x1F).
            let value = scalar.value
            if (0x40...0x7E).contains(value) {
                return [UInt8(value & 0x1F)]
            }
        }

        guard let characters = event.characters, !characters.isEmpty else { return nil }
        // Return sends CR, not LF — the pty's line discipline turns that
        // into whatever the child's terminal driver expects.
        if characters == "\r" || characters == "\n" { return [0x0D] }
        return Array(characters.utf8)
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
        default: return nil
        }
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

    private static func escape(_ final: String) -> [UInt8] {
        Array("\u{1B}[\(final)".utf8)
    }
}
