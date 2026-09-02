import AppKit

/// Mouse reporting (M2.7, SGR ?1006): click and release events are
/// translated to SGR report bytes when the child asked for them. The stored
/// properties these methods use (`isMouseReportingEnabled`, `onMouseBytes`,
/// `cellSize`) live on the class itself — extensions cannot add storage.
extension TerminalView {
    override func mouseDown(with event: NSEvent) {
        if report(event, phase: .press(.left)) { return }
        // Mouse reporting is off, so the left button selects text (M3.7).
        // The shell owns the selection state; it is reached through the
        // window rather than a stored closure because extensions cannot add
        // storage to the class.
        guard let controller = window?.contentViewController as? ViewController else {
            super.mouseDown(with: event)
            return
        }
        controller.handleSelectionMouseDown(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.left)) else { super.mouseUp(with: event); return }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard report(event, phase: .press(.right)) else { super.rightMouseDown(with: event); return }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.right)) else { super.rightMouseUp(with: event); return }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard report(event, phase: .press(.middle)) else { super.otherMouseDown(with: event); return }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.middle)) else { super.otherMouseUp(with: event); return }
    }

    private enum MousePhase {
        case press(SGRMouse.Button)
        case release(SGRMouse.Button)
    }

    /// Sends the SGR report for one event; returns false when mouse reporting
    /// is off and the event should follow its normal path.
    private func report(_ event: NSEvent, phase: MousePhase) -> Bool {
        guard isMouseReportingEnabled?() == true, cellSize.width > 0, cellSize.height > 0
        else { return false }
        let (column, row) = cellUnder(event)
        let modifiers = Self.mouseModifiers(of: event)
        let bytes: [UInt8]
        switch phase {
        case .press(let button):
            bytes = SGRMouse.press(button: button, column: column, row: row, modifiers: modifiers)
        case .release(let button):
            bytes = SGRMouse.release(button: button, column: column, row: row, modifiers: modifiers)
        }
        onMouseBytes?(bytes)
        return true
    }

    /// The cell under the event, in grid coordinates. Also used by the
    /// scroll-wheel SGR report in `TerminalView+Scroll.swift`.
    func cellUnder(_ event: NSEvent) -> (column: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return SGRMouse.cell(for: point, cellWidth: cellSize.width, cellHeight: cellSize.height)
    }

    static func mouseModifiers(of event: NSEvent) -> SGRMouse.Modifiers {
        var modifiers = SGRMouse.Modifiers()
        modifiers.shift = event.modifierFlags.contains(.shift)
        modifiers.meta = event.modifierFlags.contains(.option)
        modifiers.control = event.modifierFlags.contains(.control)
        return modifiers
    }
}
