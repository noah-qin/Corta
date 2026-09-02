import AppKit

/// Scrolling (M1.20): the wheel, page keys and ⌘↑/⌘↓ resolve to a
/// `ScrollGesture` the shell applies to the scrollback viewport.
extension TerminalView {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        // With mouse reporting on, the wheel belongs to the child (SGR 64/65
        // per notch), not to the scrollback.
        if isMouseReportingEnabled?() == true, cellSize.width > 0, cellSize.height > 0 {
            let (column, row) = cellUnder(event)
            onMouseBytes?(
                SGRMouse.wheel(
                    up: event.scrollingDeltaY > 0, column: column, row: row,
                    modifiers: Self.mouseModifiers(of: event)))
            return
        }
        // Two fingers down reveals older lines, which is what every other
        // terminal does. AppKit has already applied the user's natural-
        // scrolling preference to `scrollingDeltaY`, so the raw sign is the
        // one to follow — negating it here inverted the gesture for everyone.
        // One line per ~10pt keeps momentum scrolling proportionate without
        // needing a config knob.
        let lines = Int((event.scrollingDeltaY / 10).rounded())
        guard lines != 0 else { return }
        onScroll?(.lines(lines))
    }

    override func scrollPageUp(_ sender: Any?) { onScroll?(.page(up: true)) }
    override func scrollPageDown(_ sender: Any?) { onScroll?(.page(up: false)) }

    /// ⌘↑ / ⌘↓ jump to the top and bottom of scrollback, the same gesture
    /// most terminals and pagers use — checked before `bytes(for:)` so a
    /// held ⌘ never leaks an arrow escape sequence to the child.
    static func scrollGesture(for event: NSEvent) -> ScrollGesture? {
        guard event.modifierFlags.contains(.command) else { return nil }
        switch event.specialKey {
        case .some(.upArrow): return .toTop
        case .some(.downArrow): return .toBottom
        default: return nil
        }
    }
}
