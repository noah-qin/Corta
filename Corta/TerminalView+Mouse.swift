import AppKit

/// Mouse reporting (M2.7, SGR ?1006): click and release events are
/// translated to SGR report bytes when the child asked for them. The stored
/// properties these methods use (`isMouseReportingEnabled`, `onMouseBytes`,
/// `cellSize`) live on the class itself — extensions cannot add storage.
extension TerminalView {
    override func mouseDown(with event: NSEvent) {
        // M5.2: a click focuses its pane — keyboard input follows focus, and
        // focus is the only routing rule a split window has. Not while the
        // pane's search bar owns the keyboard, though: clicking a match with
        // the bar open must not strand the bar.
        if paneController?.searchBar == nil {
            window?.makeFirstResponder(self)
        }
        // ⌘-click opens a link (M4.6) before anything else sees the click —
        // it is neither an SGR report nor the start of a selection.
        if event.modifierFlags.contains(.command),
            let controller = paneController,
            controller.handleLinkClick(event, in: self)
        { return }
        if report(event, phase: .press(.left)) { return }
        // Mouse reporting is off, so the left button selects text (M3.7).
        // The shell owns the selection state; it is reached through the
        // responder chain rather than a stored closure because extensions
        // cannot add storage to the class.
        guard let controller = paneController else {
            super.mouseDown(with: event)
            return
        }
        controller.handleSelectionMouseDown(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard report(event, phase: .release(.left)) else { super.mouseUp(with: event); return }
    }

    override func rightMouseDown(with event: NSEvent) {
        if report(event, phase: .press(.right)) { return }
        // Mouse reporting is off: the right button belongs to the pane's
        // context menu (copy/paste, split, close). The click focuses the
        // pane first so the menu acts on what the user is looking at.
        if paneController?.searchBar == nil {
            window?.makeFirstResponder(self)
        }
        if let menu = paneController?.contextMenu(for: self) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
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
        cellUnder(point: convert(event.locationInWindow, from: nil))
    }

    /// The shell's inset-aware, bottom-anchored mapping when wired (it is,
    /// in the app); the raw divide remains the fallback for an unwired view.
    func cellUnder(point: CGPoint) -> (column: Int, row: Int) {
        if let cellAtPoint { return cellAtPoint(point) }
        return SGRMouse.cell(for: point, cellWidth: cellSize.width, cellHeight: cellSize.height)
    }

    static func mouseModifiers(of event: NSEvent) -> SGRMouse.Modifiers {
        var modifiers = SGRMouse.Modifiers()
        modifiers.shift = event.modifierFlags.contains(.shift)
        modifiers.meta = event.modifierFlags.contains(.option)
        modifiers.control = event.modifierFlags.contains(.control)
        return modifiers
    }

    // MARK: - ⌘-hover link feedback (M4.6)

    override func mouseMoved(with event: NSEvent) {
        guard let controller = paneController else {
            super.mouseMoved(with: event)
            return
        }
        controller.handleLinkHover(event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        paneController?.resetLinkHover(self)
    }

    /// ⌘ pressed or released while the pointer rests still: `locationInWindow`
    /// is valid on flags-changed events, so hover feedback refreshes in place.
    override func flagsChanged(with event: NSEvent) {
        guard let controller = paneController else {
            super.flagsChanged(with: event)
            return
        }
        controller.handleLinkHover(event, in: self)
    }
}
