import AppKit
import CortaTerminal

/// Routes a gesture to the subscribed TUI or to local text selection.
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
        showMouseOverrideHintIfNeeded()
        if report(event, phase: .press(.left)) { return }
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

    var effectiveMouseTrackingMode: MouseTrackingMode {
        mouseTrackingMode?() ?? (isMouseReportingEnabled?() == true ? .normal : .off)
    }

    func overridesMouseReporting(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(mouseOverrideModifier.flags)
    }

    func showMouseOverrideHintIfNeeded() {
        guard effectiveMouseTrackingMode != .off, !didShowMouseOverrideHint else { return }
        didShowMouseOverrideHint = true
        showToast(L10n.format("toast.mouseOverride", mouseOverrideModifier.symbol))
    }

    /// A release is only sent for a press we delivered. Gesture ownership is
    /// fixed at mouse-down, so releasing the override cannot leak a report.
    private func report(_ event: NSEvent, phase: MousePhase) -> Bool {
        guard effectiveMouseTrackingMode != .off, cellSize.width > 0, cellSize.height > 0 else {
            reportedMouseButtons.removeAll()
            lastMouseReportCell = nil
            return false
        }
        let (column, row) = cellUnder(event)
        let modifiers = Self.mouseModifiers(of: event)
        let bytes: [UInt8]
        switch phase {
        case .press(let button):
            guard !overridesMouseReporting(event) else { return false }
            reportedMouseButtons.insert(button.code)
            bytes = SGRMouse.press(button: button, column: column, row: row, modifiers: modifiers)
        case .release(let button):
            guard reportedMouseButtons.remove(button.code) != nil else { return false }
            bytes = SGRMouse.release(button: button, column: column, row: row, modifiers: modifiers)
        }
        lastMouseReportCell = (column, row)
        onMouseBytes?(bytes)
        return true
    }

    override func mouseDragged(with event: NSEvent) { reportMotion(event, button: .left) }
    override func rightMouseDragged(with event: NSEvent) { reportMotion(event, button: .right) }
    override func otherMouseDragged(with event: NSEvent) { reportMotion(event, button: .middle) }

    private func reportMotion(_ event: NSEvent, button: SGRMouse.Button?) {
        let mode = effectiveMouseTrackingMode
        guard mode == .anyEvent || (mode == .buttonEvent && button != nil),
            cellSize.width > 0, cellSize.height > 0 else { return }
        if let button {
            guard reportedMouseButtons.contains(button.code) else { return }
        } else if overridesMouseReporting(event) { return }
        let cell = cellUnder(event)
        guard lastMouseReportCell?.column != cell.column || lastMouseReportCell?.row != cell.row else { return }
        lastMouseReportCell = cell
        onMouseBytes?(SGRMouse.motion(button: button, column: cell.column, row: cell.row,
                                     modifiers: Self.mouseModifiers(of: event)))
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
        reportMotion(event, button: nil)
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
