import AppKit

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

    /// The direct translation, run for events the IME never saw or declined.
    func deliverBytes(for event: NSEvent) {
        guard let bytes = Self.bytes(for: event) else {
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
    static func bytes(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags

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

    private static func escape(_ final: String) -> [UInt8] {
        Array("\u{1B}[\(final)".utf8)
    }
}
