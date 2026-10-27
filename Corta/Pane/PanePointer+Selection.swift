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

extension PanePointer {
    // MARK: - Mouse selection

    /// Local selection owns the gesture from mouse-down, even if the override
    /// modifier is released.
    func handleSelectionMouseDown(_ event: NSEvent, in terminalView: TerminalView) {
        guard let window = terminalView.window, session != nil, terminalRenderer != nil
        else { return }
        var grid = session.snapshot()
        let gesture = beginSelection(event, in: terminalView, grid: grid)

        // Periodic events, not a Timer: `nextEvent(matching:)`'s modal wait
        // doesn't run the run loop.
        NSEvent.startPeriodicEvents(afterDelay: 0.2, withPeriod: 1.0 / 30.0)
        defer { NSEvent.stopPeriodicEvents() }
        while true {
            guard Self.gestureContinues(in: terminalView, window: window) else { return }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic])
            else { continue }
            // Again after the wait: focus may have gone while it blocked.
            guard Self.gestureContinues(in: terminalView, window: window) else { return }
            grid = session.snapshot()
            if next.type == .periodic {
                dragAutoScrollTick(in: terminalView, grid: grid, anchor: gesture.anchor, unit: gesture.unit)
                continue
            }
            let head = documentPosition(for: next, in: terminalView, grid: grid)
            if next.type == .leftMouseUp {
                endSelection(gesture, at: head, grid: grid, event: next, in: terminalView)
                return
            }
            if head != gesture.anchor || gesture.unit != .character {
                applySelection(anchor: gesture.anchor, head: head, unit: gesture.unit, grid: grid)
            }
        }
    }

    /// What a drag selects from: where it started, by what unit, and whether
    /// it extends the existing selection.
    private struct SelectionGesture {
        var anchor: SelectionPoint
        var unit: SelectionUnit
        var extending: Bool
    }

    /// The pane may close, or a tab detach may reparent it, mid-drag; stop
    /// rather than touch a torn-down pane. Losing key (Cmd-Tab, Mission
    /// Control) ends the gesture, rather than extend the selection in the
    /// background.
    private static func gestureContinues(in terminalView: TerminalView, window: NSWindow) -> Bool {
        terminalView.window === window && window.isKeyWindow
    }

    /// The click's anchor and unit — a word on a double click, a logical line
    /// on a triple — and the selection it starts with.
    private func beginSelection(_ event: NSEvent, in terminalView: TerminalView, grid: Grid) -> SelectionGesture {
        var anchor = documentPosition(for: event, in: terminalView, grid: grid)
        // Shift as the reporting override starts fresh; otherwise it extends.
        let shiftIsOverride = terminalView.effectiveMouseTrackingMode != .off
            && terminalView.mouseOverrideModifier == .shift
        let extending = event.modifierFlags.contains(.shift) && !shiftIsOverride
        let unit: SelectionUnit
        switch event.clickCount {
        case 2: unit = .word
        case 3...: unit = .logicalLine
        default: unit = .character
        }

        if extending, unit == .character, let existing = selection {
            // Extend from the end farther from the click.
            let current = selectionRange(for: existing, in: grid)
            anchor = anchor <= current.start ? current.end : current.start
        } else if unit == .character {
            clearSelection()
        } else {
            applySelection(anchor: anchor, head: anchor, unit: unit, grid: grid)
        }
        return SelectionGesture(anchor: anchor, unit: unit, extending: extending)
    }

    /// Mouse-up. A plain click that never moved stays cleared, and with
    /// `link-activation = click` opens what it was on — on mouse-up, so a
    /// drag still selects.
    private func endSelection(
        _ gesture: SelectionGesture, at head: SelectionPoint, grid: Grid, event: NSEvent,
        in terminalView: TerminalView
    ) {
        guard head != gesture.anchor || gesture.unit != .character || gesture.extending else {
            openLinkOnPlainClick(event, in: terminalView)
            return
        }
        applySelection(anchor: gesture.anchor, head: head, unit: gesture.unit, grid: grid)
        // On mouse-up only, not per drag position.
        if ConfigurationStore.shared.configuration.copyOnSelect { host?.commands.copy(nil) }
    }

    /// One auto-scroll tick while the pointer is past an edge: scroll and
    /// re-extend the head; `autoScrollTick` stops at the scrollback's ends.
    private func dragAutoScrollTick(
        in terminalView: TerminalView, grid: Grid, anchor: SelectionPoint, unit: SelectionUnit
    ) {
        guard let window = terminalView.window else { return }
        // The live pointer: the periodic event's is stale when parked.
        let point = terminalView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let tick = Self.autoScrollTick(
            at: point, grid: grid, scrollOffset: scrollOffset, historyDepth: grid.scrollback.count,
            in: GridGeometry(
                viewHeight: terminalView.bounds.height, metrics: terminalRenderer.pointMetrics, topInset: topInset))
        else { return }
        scrollOffset = tick.scrollOffset
        // No grid output to trigger a redraw, as in `scroll(_:)`.
        invalidateDisplay()
        if tick.head != anchor || unit != .character {
            applySelection(anchor: anchor, head: tick.head, unit: unit, grid: grid)
        }
    }

    private func applySelection(
        anchor: SelectionPoint, head: SelectionPoint, unit: SelectionUnit, grid: Grid
    ) {
        setSelection(Selection.range(from: anchor, to: head, unit: unit, in: grid), in: grid)
    }

    /// Selects `range` of `grid`, recording what it covers from that same
    /// grid: a rewrite that lands before the next frame is then a change, not
    /// the baseline (#341).
    func setSelection(_ range: SelectionRange, in grid: Grid) {
        let selection = TerminalSelection(range, grid: grid)
        self.selection = selection
        selectionContent = (selection, Selection.content(of: range, in: grid))
        // No output batch reports a local change.
        terminalView?.noteAccessibilitySelectionChanged()
        invalidateDisplay()
    }

    func clearSelection() {
        selection = nil
        selectionContent = nil
        terminalView?.noteAccessibilitySelectionChanged()
        invalidateDisplay()
    }

    /// Drops the selection once the program rewrites the text it covers,
    /// which otherwise leaves the highlight on text it no longer names
    /// (#341). Once per frame, and before a copy or an export reads it. A
    /// selection made here was recorded as it was made; one set elsewhere is
    /// recorded against the first grid it meets.
    func dropSelectionIfRewritten(in grid: Grid) {
        guard let selection else {
            selectionContent = nil
            return
        }
        guard let recorded = selectionContent, recorded.selection == selection else {
            selectionContent = (
                selection, Selection.content(of: selectionRange(for: selection, in: grid), in: grid))
            return
        }
        guard !Selection.isUnchanged(recorded.content, in: grid) else { return }
        clearSelection()
    }

    /// The selection against the current grid: rows shift by lines pushed
    /// since `baseScrollbackTotal` (never negative). `totalPushed`, not
    /// `count`, which saturates once the ring evicts.
    func selectionRange(for selection: TerminalSelection, in grid: Grid) -> SelectionRange {
        let range = SelectionRange(
            start: SelectionPoint(row: selection.start.row, column: selection.start.column),
            end: SelectionPoint(row: selection.end.row, column: selection.end.column))
        return range.reanchored(from: selection.baseScrollbackTotal, to: grid.scrollback.totalPushed)
    }

    func documentPosition(for event: NSEvent, in terminalView: TerminalView, grid: Grid)
        -> SelectionPoint
    {
        Self.documentPosition(
            for: terminalView.convert(event.locationInWindow, from: nil), grid: grid, scrollOffset: scrollOffset,
            in: GridGeometry(
                viewHeight: terminalView.bounds.height, metrics: terminalRenderer.pointMetrics, topInset: topInset))
    }

    /// Pure, for tests. Mirrors `PaneFrameLoop.contentRect(in:scale:gridHeight:topInset:)`:
    /// top-anchored when the grid fits, bottom-anchored while it overflows.
    nonisolated static func documentPosition(
        for point: CGPoint, grid: Grid, scrollOffset: Int, in geometry: GridGeometry
    ) -> SelectionPoint {
        let metrics = geometry.metrics
        let gridTop = geometry.gridTop(rows: grid.rows)
        let column = Int(((point.x - TerminalLayout.insets.left) / metrics.cellWidth).rounded(.down))
        let row = Int(((point.y - gridTop) / metrics.cellHeight).rounded(.down))
        return SelectionPoint(
            row: min(max(0, row), grid.rows - 1) - scrollOffset,
            column: min(max(0, column), grid.columns - 1))
    }

    /// Pure: nil inside the grid or when the offset can't move; otherwise the
    /// new offset and head. One row per tick near the edge, one more per two
    /// cell heights of overshoot, capped: 30–240 rows/s at 30 ticks.
    nonisolated static func autoScrollTick(
        at point: CGPoint, grid: Grid, scrollOffset: Int, historyDepth: Int, in geometry: GridGeometry
    ) -> (scrollOffset: Int, head: SelectionPoint)? {
        let metrics = geometry.metrics
        let gridHeight = CGFloat(grid.rows) * metrics.cellHeight
        let gridTop = geometry.gridTop(rows: grid.rows)
        let upward = point.y < gridTop
        let overshoot =
            upward
            ? gridTop - point.y
            : max(0, point.y - (gridTop + gridHeight))
        guard overshoot > 0 else { return nil }
        let rows = min(1 + Int(overshoot / (2 * metrics.cellHeight)), 8)
        let newOffset = min(max(0, scrollOffset + (upward ? rows : -rows)), max(0, historyDepth))
        guard newOffset != scrollOffset else { return nil }
        let head = documentPosition(for: point, grid: grid, scrollOffset: newOffset, in: geometry)
        return (scrollOffset: newOffset, head: head)
    }

    // MARK: - Scroll position

    /// Shows, hides or re-labels the pill to match the viewport.
    ///
    /// Cheap enough to call from `scrollOffset`'s `didSet` and from the frame
    /// path: it touches no grid and allocates only when the text changes.
    func updateScrollPositionIndicator() {
        guard isOperable, let terminalView else {
            scrollPositionIndicator?.removeFromSuperview()
            scrollPositionIndicator = nil
            return
        }
        guard scrollOffset > 0 else {
            scrollPositionIndicator?.removeFromSuperview()
            scrollPositionIndicator = nil
            return
        }
        let indicator = scrollPositionIndicator ?? installScrollPositionIndicator(on: terminalView)
        indicator.update(linesBack: scrollOffset, hasNewOutput: host?.sawOutputWhileScrolled ?? false)
    }

    private func installScrollPositionIndicator(on terminalView: TerminalView)
        -> ScrollPositionIndicator
    {
        let indicator = ScrollPositionIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.onReturnToBottom = { [weak self] in self?.returnToBottom() }
        terminalView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(
                equalTo: terminalView.trailingAnchor, constant: -12),
            indicator.bottomAnchor.constraint(
                equalTo: terminalView.bottomAnchor, constant: -10),
        ])
        scrollPositionIndicator = indicator
        return indicator
    }

    /// The return-to-bottom affordance, reachable three ways: the pill, the
    /// Scroll to Bottom command, and — because a person who has scrolled up
    /// and starts typing means to be at the prompt — the next keystroke
    /// (`returnToBottomOnInput`).
    func returnToBottom() {
        scroll(.toBottom)
    }
}
