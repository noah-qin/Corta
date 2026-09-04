import AppKit

/// Mouse reporting (M2.7, SGR ?1006): click and release events are
/// translated to SGR report bytes when the child asked for them — except
/// the left button, whose gesture might turn into a drag, so it is decided
/// in `handleSelectionMouseDown` rather than here. The stored properties
/// these methods use (`isMouseReportingEnabled`, `onMouseBytes`, `cellSize`)
/// live on the class itself — extensions cannot add storage.
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
        // A left mouse down never picks between reporting and selection by
        // itself — whether the child gets it depends on what the gesture
        // turns out to be, which isn't known until it ends (see
        // `handleSelectionMouseDown`'s doc comment). With no controller to
        // make that call there is no selection state to defer to, so an
        // unwired view (tests) keeps the old immediate-report-or-not
        // behaviour.
        guard let controller = paneController else {
            if !report(event, phase: .press(.left)) { super.mouseDown(with: event) }
            return
        }
        controller.handleSelectionMouseDown(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        // The left button's up event is consumed inside
        // `handleSelectionMouseDown`'s own tracking loop and never reaches
        // here through the normal responder chain; this override only ever
        // fires for the unwired fallback above, or another button.
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

    /// Sends the press-then-release pair for a left click that
    /// `handleSelectionMouseDown` has determined, only once the gesture is
    /// over, never turned into a drag — the report was withheld until that
    /// was known, so it goes out retroactively, both halves at once.
    func reportClick(down: NSEvent, up: NSEvent) {
        _ = report(down, phase: .press(.left))
        _ = report(up, phase: .release(.left))
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
