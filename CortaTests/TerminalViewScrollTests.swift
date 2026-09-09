import AppKit
import Testing

@testable import Corta

/// U03: precise trackpad points and discrete wheel lines are separate
/// units, each accumulated across events so sub-line deltas carry into
/// whole lines instead of rounding away. The view-level cases drive
/// `scrollWheel(with:)` with synthetic CGEvent-backed scroll events;
/// AppKit reads units and phases back off them exactly as it does for
/// hardware events.
@MainActor
struct TerminalViewScrollTests {
    private static func scrollEvent(
        deltaY: Int32, units: CGScrollEventUnit,
        phase: CGScrollPhase? = nil, momentumPhase: CGMomentumScrollPhase? = nil
    ) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0)!
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentumPhase {
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        }
        return NSEvent(cgEvent: cg)!
    }

    private static func makeView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.cellSize = CGSize(width: 8, height: 17)
        return view
    }

    private static func lineCount(of gesture: ScrollGesture?) -> Int? {
        guard case .some(.lines(let lines)) = gesture else { return nil }
        return lines
    }

    // MARK: - Accumulator units

    @Test func trackpadFractionalDeltasCarryAcrossEvents() {
        let accumulator = ScrollWheelAccumulator()
        // 10pt per line: three 4pt trackpad deltas emit exactly one line,
        // on the event that crosses the threshold — per-event rounding
        // dropped all three.
        #expect(accumulator.lines(precisePoints: 4) == 0)
        #expect(accumulator.lines(precisePoints: 4) == 0)
        #expect(accumulator.lines(precisePoints: 4) == 1)
        #expect(accumulator.lines(precisePoints: 8) == 1)
        #expect(accumulator.lines(precisePoints: 4) == 0)
    }

    @Test func reverseFlickCancelsTheAccumulatedFraction() {
        let accumulator = ScrollWheelAccumulator()
        #expect(accumulator.lines(precisePoints: 6) == 0)
        // Backing off 6pt returns to the start: no phantom line either way.
        #expect(accumulator.lines(precisePoints: -6) == 0)
        #expect(accumulator.lines(precisePoints: -6) == 0)
        #expect(accumulator.lines(precisePoints: -6) == -1)
    }

    @Test func wheelNotchesPassThroughAsWholeLines() {
        let accumulator = ScrollWheelAccumulator()
        // The pre-U03 code divided every delta by 10 points, so a single
        // 1-line notch rounded to zero and the scrollback never moved.
        #expect(accumulator.lines(discreteLines: 1) == 1)
        #expect(accumulator.lines(discreteLines: 3) == 3)
        #expect(accumulator.lines(discreteLines: -2) == -2)
    }

    @Test func fractionalWheelStepsAccumulateInLineUnits() {
        let accumulator = ScrollWheelAccumulator()
        #expect(accumulator.lines(discreteLines: 0.5) == 0)
        #expect(accumulator.lines(discreteLines: 0.5) == 1)
        #expect(accumulator.lines(discreteLines: -1.5) == -1)
    }

    @Test func trackpadAndWheelUnitsDoNotMix() {
        let accumulator = ScrollWheelAccumulator()
        // 6pt of trackpad leftover (0.6 line) must not top up a fractional
        // wheel step: a single mixed pot would emit a line at the second
        // call (0.6 + 0.5 = 1.1).
        #expect(accumulator.lines(precisePoints: 6) == 0)
        #expect(accumulator.lines(discreteLines: 0.5) == 0)
        // Each pot keeps its own remainder.
        #expect(accumulator.lines(discreteLines: 0.5) == 1)
        #expect(accumulator.lines(precisePoints: 4) == 1)
    }

    // MARK: - scrollWheel(with:) end to end

    @Test func syntheticEventsCarryTheirDeviceUnits() {
        // The view's precise/discrete branch keys off these, so pin the
        // CGEvent → NSEvent mapping the rest of the suite relies on.
        let pixel = Self.scrollEvent(deltaY: 4, units: .pixel)
        #expect(pixel.hasPreciseScrollingDeltas)
        #expect(pixel.scrollingDeltaY == 4)
        let line = Self.scrollEvent(deltaY: 1, units: .line)
        #expect(!line.hasPreciseScrollingDeltas)
        #expect(line.scrollingDeltaY == 1)
    }

    @Test func wheelMouseNotchScrollsOneLine() {
        let view = Self.makeView()
        var scrolled: ScrollGesture?
        view.onScroll = { scrolled = $0 }
        view.scrollWheel(with: Self.scrollEvent(deltaY: 1, units: .line))
        #expect(Self.lineCount(of: scrolled) == 1)
        view.scrollWheel(with: Self.scrollEvent(deltaY: -2, units: .line))
        #expect(Self.lineCount(of: scrolled) == -2)
    }

    @Test func trackpadPixelDeltasAccumulateAcrossEvents() {
        let view = Self.makeView()
        var gestures: [ScrollGesture] = []
        view.onScroll = { gestures.append($0) }
        for _ in 0..<3 {
            view.scrollWheel(with: Self.scrollEvent(
                deltaY: 4, units: .pixel, phase: .changed))
        }
        #expect(gestures.count == 1)
        #expect(Self.lineCount(of: gestures.first) == 1)
    }

    /// Momentum continues the same accumulator: a line is emitted exactly
    /// when the running total crosses `pointsPerLine`, and a phase transition
    /// on its own neither emits a line nor swallows the remainder.
    ///
    /// The arithmetic is spelled out because it is the whole assertion —
    /// `pointsPerLine` is 10, and the five events below sum to 22 points, so
    /// two lines are owed in total and the third is not.
    @Test func momentumTailSumsInsteadOfRefiring() {
        let view = Self.makeView()
        var gestures: [ScrollGesture] = []
        view.onScroll = { gestures.append($0) }
        // Fingers down: 4 + 2 = 6pt, still sub-line, so nothing fires.
        view.scrollWheel(with: Self.scrollEvent(deltaY: 4, units: .pixel, phase: .began))
        view.scrollWheel(with: Self.scrollEvent(deltaY: 2, units: .pixel, phase: .changed))
        #expect(gestures.isEmpty)
        // Fingers lift. The remainder carries into momentum rather than
        // being dropped at the transition: 6 + 4 = 10pt is the first line.
        view.scrollWheel(with: Self.scrollEvent(
            deltaY: 4, units: .pixel, momentumPhase: .begin))
        #expect(gestures.count == 1)
        #expect(Self.lineCount(of: gestures.first) == 1)
        // 8pt more: 8 of the next 10, so still nothing — the transition into
        // the deceleration tail does not refire the line just emitted.
        // kCGMomentumScrollPhaseContinue has no Swift case name (it would be
        // the `continue` keyword), so the raw value stands in for it here.
        view.scrollWheel(with: Self.scrollEvent(
            deltaY: 8, units: .pixel, momentumPhase: CGMomentumScrollPhase(rawValue: 2)))
        #expect(gestures.count == 1)
        // 4pt more crosses the second line at 22pt total, and the 2pt over
        // stays as the remainder rather than rounding into a third.
        view.scrollWheel(with: Self.scrollEvent(
            deltaY: 4, units: .pixel, momentumPhase: .end))
        #expect(gestures.count == 2)
        #expect(Self.lineCount(of: gestures.last) == 1)
    }

    @Test func mouseReportingTurnsTheWheelIntoSGRReports() {
        let view = Self.makeView()
        view.isMouseReportingEnabled = { true }
        view.cellAtPoint = { _ in (column: 5, row: 3) }
        var mouseBytes: [[UInt8]] = []
        var scrolled: ScrollGesture?
        view.onMouseBytes = { mouseBytes.append($0) }
        view.onScroll = { scrolled = $0 }
        view.scrollWheel(with: Self.scrollEvent(deltaY: 1, units: .line))
        view.scrollWheel(with: Self.scrollEvent(deltaY: -1, units: .pixel, momentumPhase: .begin))
        // SGR 64/65 per event, no accumulation, scrollback untouched.
        #expect(mouseBytes == [
            Array("\u{1B}[<64;6;4M".utf8),
            Array("\u{1B}[<65;6;4M".utf8),
        ])
        #expect(scrolled == nil)
        // Reporting off again: the wheel belongs to the scrollback, and
        // the precise accumulator starts clean rather than inheriting
        // anything from the reported events above.
        view.isMouseReportingEnabled = { false }
        view.scrollWheel(with: Self.scrollEvent(deltaY: -1, units: .line))
        #expect(Self.lineCount(of: scrolled) == -1)
    }

    @Test func accumulatorsArePerView() {
        let viewA = Self.makeView()
        let viewB = Self.makeView()
        var scrolledA: ScrollGesture?
        var scrolledB: ScrollGesture?
        viewA.onScroll = { scrolledA = $0 }
        viewB.onScroll = { scrolledB = $0 }
        // A shared pot would already emit a line on view B's 6pt.
        viewA.scrollWheel(with: Self.scrollEvent(deltaY: 6, units: .pixel))
        viewB.scrollWheel(with: Self.scrollEvent(deltaY: 6, units: .pixel))
        #expect(scrolledA == nil)
        #expect(scrolledB == nil)
        viewA.scrollWheel(with: Self.scrollEvent(deltaY: 4, units: .pixel))
        #expect(Self.lineCount(of: scrolledA) == 1)
        #expect(scrolledB == nil)
    }
}
