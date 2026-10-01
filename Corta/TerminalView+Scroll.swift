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

/// Sub-line scroll remainders for one view, per device: trackpads report
/// points, wheels lines, and rounding per event would lose small deltas.
/// The two never combine.
final class ScrollWheelAccumulator {
    /// Trackpad points per line.
    static let pointsPerLine: CGFloat = 10

    private var precisePoints: CGFloat = 0
    private var discreteLines: CGFloat = 0

    func lines(for event: NSEvent) -> Int {
        event.hasPreciseScrollingDeltas
            ? lines(precisePoints: event.scrollingDeltaY)
            : lines(discreteLines: event.scrollingDeltaY)
    }

    /// Truncating keeps the signed remainder, so a reverse flick cancels
    /// rather than emitting a phantom line.
    func lines(precisePoints delta: CGFloat) -> Int {
        let total = precisePoints + delta
        let lines = Int(total / Self.pointsPerLine)
        precisePoints = total - CGFloat(lines) * Self.pointsPerLine
        return lines
    }

    /// Wheel deltas are lines already.
    func lines(discreteLines delta: CGFloat) -> Int {
        let total = discreteLines + delta
        let lines = Int(total)
        discreteLines = total - CGFloat(lines)
        return lines
    }
}

/// Per-view accumulators (extensions have no storage); main thread only.
private let scrollWheelAccumulators = NSMapTable<TerminalView, ScrollWheelAccumulator>(
    keyOptions: .weakMemory, valueOptions: .strongMemory)

/// Scrolling: wheel, page keys and the Scroll to Top/Bottom bindings, as
/// a `ScrollGesture`.
extension TerminalView {
    override func scrollWheel(with event: NSEvent) {
        noteScrollGesturePhase(event)
        guard event.scrollingDeltaY != 0 else { return }
        // With mouse reporting on, the wheel goes to the child (SGR 64/65):
        // one report per line accumulated, as for local scrolling. One per
        // event sent a trackpad's every point-sized delta, momentum included,
        // as a whole notch — vim and tmux scrolled many times too fast.
        if effectiveMouseTrackingMode != .off, !overridesMouseReporting(event), cellSize.width > 0, cellSize.height > 0 {
            let lines = scrollWheelAccumulator.lines(for: event)
            guard lines != 0 else { return }
            let (column, row) = cellUnder(event)
            let report = SGRMouse.wheel(
                up: lines > 0, column: column, row: row, modifiers: Self.mouseModifiers(of: event))
            onMouseBytes?(Array(repeating: report, count: min(abs(lines), Self.maximumWheelRepeat)).flatMap { $0 })
            return
        }
        // Follow the raw sign: AppKit already applied natural scrolling, and
        // negating it inverted the gesture. Momentum sums through the same
        // accumulator.
        let lines = scrollWheelAccumulator.lines(for: event)
        guard lines != 0 else { return }
        onScroll?(.lines(lines))
    }

    /// Reports or arrow keys sent for one wheel event, however fast the flick.
    static let maximumWheelRepeat = 24

    private var scrollWheelAccumulator: ScrollWheelAccumulator {
        if let existing = scrollWheelAccumulators.object(forKey: self) { return existing }
        let created = ScrollWheelAccumulator()
        scrollWheelAccumulators.setObject(created, forKey: self)
        return created
    }

    override func scrollPageUp(_ sender: Any?) { onScroll?(.page(up: true)) }
    override func scrollPageDown(_ sender: Any?) { onScroll?(.page(up: false)) }

    /// Reports trackpad phases so `RenderPolicy` lifts the rate ceiling while
    /// scrolling. Wheels have no phase (`RenderPolicy.scrollingStateChanged`).
    private func noteScrollGesturePhase(_ event: NSEvent) {
        // Option sets: test membership.
        if event.phase.contains(.began) {
            renderPolicy?.scrollingStateChanged(true)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            renderPolicy?.scrollingStateChanged(false)
        }
        // Momentum is its own phase, or the rate drops as fingers lift.
        if event.momentumPhase.contains(.began) {
            renderPolicy?.scrollingStateChanged(true)
        } else if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            renderPolicy?.scrollingStateChanged(false)
        }
    }

    /// The Scroll to Top/Bottom bindings, checked before `bytes(for:)`, for
    /// keys AppKit didn't dispatch through the menu. From the bindings, never
    /// a literal, which would be an invisible second binding.
    static func scrollGesture(for event: NSEvent, bindings: Keybindings) -> ScrollGesture? {
        if bindings[.scrollToTop]?.matches(event) == true { return .toTop }
        if bindings[.scrollToBottom]?.matches(event) == true { return .toBottom }
        return nil
    }
}
