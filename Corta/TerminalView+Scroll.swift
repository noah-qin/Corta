import AppKit

/// U03: the leftover sub-line scroll distance for one view, kept per device
/// class. Trackpads report *precise* deltas in points, wheel mice report
/// lines (usually whole, occasionally fractional); rounding each event on
/// its own rounded small trackpad deltas away to nothing and dropped a
/// wheel notch entirely (a 1-line notch is 1/10 of the old per-event
/// threshold). Accumulating instead keeps the totals faithful in both
/// units. The two remainders never combine: a trackpad's leftover points
/// must not make a wheel notch count as more than a notch.
final class ScrollWheelAccumulator {
    /// Trackpad points per scrollback line — the constant M1.20 picked so
    /// momentum scrolling stays proportionate without a config knob.
    static let pointsPerLine: CGFloat = 10

    private var precisePoints: CGFloat = 0
    private var discreteLines: CGFloat = 0

    func lines(for event: NSEvent) -> Int {
        event.hasPreciseScrollingDeltas
            ? lines(precisePoints: event.scrollingDeltaY)
            : lines(discreteLines: event.scrollingDeltaY)
    }

    /// Truncating (not rounding) division keeps the signed remainder, so
    /// sub-line deltas sum across events, and a reverse flick cancels what
    /// it undid instead of emitting a phantom line.
    func lines(precisePoints delta: CGFloat) -> Int {
        let total = precisePoints + delta
        let lines = Int(total / Self.pointsPerLine)
        precisePoints = total - CGFloat(lines) * Self.pointsPerLine
        return lines
    }

    /// Wheel deltas are already in lines, so they pass through 1:1; the
    /// remainder handling only matters for the rare fractional step.
    func lines(discreteLines delta: CGFloat) -> Int {
        let total = discreteLines + delta
        let lines = Int(total)
        discreteLines = total - CGFloat(lines)
        return lines
    }
}

/// Extensions can't add stored properties, and two side-by-side panes must
/// not share leftovers, so each view's accumulator hangs off this
/// weak-keyed table. `scrollWheel` is an AppKit responder callback and
/// only ever runs on the main thread, so the table needs no locking.
private let scrollWheelAccumulators = NSMapTable<TerminalView, ScrollWheelAccumulator>(
    keyOptions: .weakMemory, valueOptions: .strongMemory)

/// Scrolling (M1.20): the wheel, the page keys and the keystrokes bound to
/// Scroll to Top / Scroll to Bottom resolve to a `ScrollGesture` the shell
/// applies to the scrollback viewport.
extension TerminalView {
    override func scrollWheel(with event: NSEvent) {
        noteScrollGesturePhase(event)
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
        // Momentum deltas arrive through the same accumulator: each event is
        // consumed exactly once, so the deceleration tail sums to whole
        // lines rather than freezing at the first sub-line event.
        let lines = scrollWheelAccumulator.lines(for: event)
        guard lines != 0 else { return }
        onScroll?(.lines(lines))
    }

    private var scrollWheelAccumulator: ScrollWheelAccumulator {
        if let existing = scrollWheelAccumulators.object(forKey: self) { return existing }
        let created = ScrollWheelAccumulator()
        scrollWheelAccumulators.setObject(created, forKey: self)
        return created
    }

    override func scrollPageUp(_ sender: Any?) { onScroll?(.page(up: true)) }
    override func scrollPageDown(_ sender: Any?) { onScroll?(.page(up: false)) }

    /// M9 — reports a trackpad gesture's begin/end to `RenderPolicy`, so
    /// it can lift the frame-rate ceiling for the couple of seconds a
    /// scroll actually lasts. A plain mouse wheel carries no phase
    /// (`event.phase` and `.momentumPhase` are both `[]`) and so never
    /// calls this at all — see `RenderPolicy.scrollingStateChanged`'s doc
    /// comment on why that is a missed enhancement for that device, not a
    /// correctness gap.
    private func noteScrollGesturePhase(_ event: NSEvent) {
        // `.contains`, not `==`: both `phase` and `momentumPhase` are
        // option sets, and Apple's own guidance checks membership rather
        // than exact equality even though a single event's phase is
        // ordinarily just one bit in practice.
        if event.phase.contains(.began) {
            renderPolicy?.scrollingStateChanged(true)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            renderPolicy?.scrollingStateChanged(false)
        }
        // Momentum (the deceleration after fingers lift) is its own phase
        // sequence, disjoint from `event.phase` above — without this, the
        // rate would drop back down the instant fingers lift even though
        // the scroll is visibly still moving.
        if event.momentumPhase.contains(.began) {
            renderPolicy?.scrollingStateChanged(true)
        } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            renderPolicy?.scrollingStateChanged(false)
        }
    }

    /// The keystrokes bound to Scroll to Top and Scroll to Bottom, checked
    /// before `bytes(for:)` so neither leaks an escape sequence to the child.
    ///
    /// This used to read ⌘↑ / ⌘↓ literally, from M1.20 — before M7.2 gave
    /// those two keys to `previous-command` and `next-command` and M7.7 gave
    /// Scroll to Top and Scroll to Bottom their own bindings (⇧Home / ⇧End).
    /// The literal outlived both. It was masked in a default install, because
    /// the Shell menu's Previous Command claims ⌘↑ and AppKit dispatches a
    /// menu key equivalent before `keyDown` runs, but `bind.previous-command
    /// =` uncovered it: unbinding one command silently turned on a different,
    /// undocumented one that Help ▸ Keyboard Shortcuts never listed (U08).
    ///
    /// The View menu's own items claim these keystrokes first, so this is the
    /// path for a keystroke AppKit did not dispatch — a menu item that failed
    /// validation, or a binding on a key AppKit will not take as a menu key
    /// equivalent — and it can now only ever answer for a key those two
    /// commands are actually bound to.
    static func scrollGesture(for event: NSEvent, bindings: Keybindings) -> ScrollGesture? {
        if bindings[.scrollToTop]?.matches(event) == true { return .toTop }
        if bindings[.scrollToBottom]?.matches(event) == true { return .toBottom }
        return nil
    }
}
