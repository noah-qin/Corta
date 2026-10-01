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

import Cocoa
import CortaTerminal

/// Scrolling, and the mouse-mode query the mouse handlers consult.
extension ViewController {
    /// Reporting needs both tracking and SGR encoding.
    func mouseReportingEnabled() -> Bool {
        (session?.sgrMouseTrackingMode ?? .off) != .off
    }

    /// Input while scrolled back returns to the bottom: it is addressed to the
    /// live screen. Output alone never moves the viewport
    /// (`scrollAnchorTotalPushed`).
    func returnToBottomOnInput() {
        guard scrollOffset > 0 else { return }
        scroll(.toBottom)
    }

    func scroll(_ gesture: ScrollGesture) {
        // The wheel on the alternate screen — `less`, `man`, `git log` — is
        // arrow keys (`?1007`); it has no scrollback to move through here.
        if case .lines(let delta) = gesture, scrollOffset == 0, session.wheelSendsArrowKeys {
            let arrow: [UInt8] =
                session.applicationCursorKeysEnabled
                ? [0x1B, 0x4F, delta > 0 ? 0x41 : 0x42]
                : [0x1B, 0x5B, delta > 0 ? 0x41 : 0x42]
            let count = min(abs(delta), TerminalView.maximumWheelRepeat)
            session.write(Array(repeating: arrow, count: count).flatMap { $0 })
            return
        }

        let historyDepth = session.snapshot().scrollback.count
        switch gesture {
        case .lines(let delta):
            scrollOffset = min(max(0, scrollOffset + delta), historyDepth)
        case .page(let up):
            let usableHeight = view.bounds.height - verticalInsets
            let rows = Int(usableHeight / terminalRenderer.pointMetrics.cellHeight)
            scrollOffset = min(max(0, scrollOffset + (up ? rows : -rows)), historyDepth)
        case .toTop:
            scrollOffset = historyDepth
        case .toBottom:
            scrollOffset = 0
        }
        // Scrolling produces no grid output to trigger a redraw.
        invalidateDisplay()
    }
}

/// Mouse selection and copy: the AppKit side of the core's
/// `Selection.swift`.
extension ViewController {
    // MARK: - Copy

    /// ⌘C through the responder chain; never reaches the PTY. The text build
    /// is O(selection) — the whole document for ⌘A — so it runs off the main
    /// actor on `largeTextTask`, like `exportText(_:)`.
    @objc func copy(_ sender: Any?) {
        guard let selection, session != nil else { return }
        let grid = session.snapshot()
        let range = selectionRange(for: selection, in: grid)
        let pasteboard = pasteboardForTesting ?? .general
        // The pasteboard is shared by every pane and app: recheck `changeCount`
        // before writing so a slow copy never clobbers a newer write.
        let changeCountAtStart = pasteboard.changeCount
        largeTextTask?.cancel()
        largeTextTaskGeneration &+= 1
        let generation = largeTextTaskGeneration
        // `.detached`, so the build is off the main actor by construction
        // rather than by inference; the pasteboard write hops back.
        let gate = largeTextBuildGateForTesting
        largeTextTask = Task.detached(priority: .userInitiated) { [weak self] in
            gate?()
            let text = Selection.text(of: range, in: grid)
            await MainActor.run {
                // Only this generation may clear the handle a newer copy installed.
                guard let self, !self.didTeardown, self.largeTextTaskGeneration == generation else { return }
                self.largeTextTask = nil
                guard !Task.isCancelled, !text.isEmpty else { return }
                let pasteboard = self.pasteboardForTesting ?? .general
                guard pasteboard.changeCount == changeCountAtStart else {
                    // Someone wrote since; their write is newer than this selection.
                    return
                }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // Confirm only a write that happened: copy-on-select is never silent.
                self.terminalView?.showToast(L10n.text("toast.copied"))
            }
        }
    }

    /// ⌘A: scrollback plus screen.
    override func selectAll(_ sender: Any?) {
        guard session != nil else { return }
        let grid = session.snapshot()
        selection = TerminalSelection(
            start: GridPosition(row: -grid.scrollback.count, column: 0),
            end: GridPosition(row: grid.rows - 1, column: grid.columns - 1),
            baseScrollbackTotal: grid.scrollback.totalPushed)
        invalidateDisplay()
    }

    // MARK: - Mouse selection

    /// Local selection owns the gesture from mouse-down, even if the override
    /// modifier is released.
    func handleSelectionMouseDown(_ event: NSEvent, in terminalView: TerminalView) {
        guard let window = terminalView.window, session != nil, terminalRenderer != nil
        else { return }
        var grid = session.snapshot()
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
            selection = nil
            terminalView.noteAccessibilitySelectionChanged()
            invalidateDisplay()
        } else {
            applySelection(anchor: anchor, head: anchor, unit: unit, grid: grid)
        }

        // Periodic events, not a Timer: `nextEvent(matching:)`'s modal wait
        // doesn't run the run loop.
        NSEvent.startPeriodicEvents(afterDelay: 0.2, withPeriod: 1.0 / 30.0)
        defer { NSEvent.stopPeriodicEvents() }
        while true {
            // The pane may close, or a tab detach may reparent it, mid-drag; stop
            // rather than touch a torn-down pane.
            guard terminalView.window === window else { return }
            // Losing key (Cmd-Tab, Mission Control) ends the gesture, rather than
            // extend the selection in the background.
            guard window.isKeyWindow else { return }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic])
            else { continue }
            guard terminalView.window === window else { return }
            // Again after the wait: focus may have gone while it blocked.
            guard window.isKeyWindow else { return }
            grid = session.snapshot()
            if next.type == .periodic {
                dragAutoScrollTick(in: terminalView, grid: grid, anchor: anchor, unit: unit)
                continue
            }
            let head = documentPosition(for: next, in: terminalView, grid: grid)
            if next.type == .leftMouseUp {
                // A plain click that never moved stays cleared.
                if head != anchor || unit != .character || extending {
                    applySelection(anchor: anchor, head: head, unit: unit, grid: grid)
                    // On mouse-up only, not per drag position.
                    if ConfigurationStore.shared.configuration.copyOnSelect { copy(nil) }
                } else {
                    // `link-activation = click`: on mouse-up, so a drag still selects.
                    openLinkOnPlainClick(next, in: terminalView)
                }
                break
            }
            if head != anchor || unit != .character {
                applySelection(anchor: anchor, head: head, unit: unit, grid: grid)
            }
        }
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
            at: point, viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, grid: grid,
            scrollOffset: scrollOffset, historyDepth: grid.scrollback.count, topInset: topInset)
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
        let range = Selection.range(from: anchor, to: head, unit: unit, in: grid)
        selection = TerminalSelection(range, grid: grid)
        // No output batch reports a local change.
        terminalView?.noteAccessibilitySelectionChanged()
        invalidateDisplay()
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
            for: terminalView.convert(event.locationInWindow, from: nil),
            viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, grid: grid, scrollOffset: scrollOffset,
            topInset: topInset)
    }

    /// Pure, for tests. Mirrors `contentRect(in:scale:gridHeight:)`:
    /// top-anchored when the grid fits, bottom-anchored while it overflows.
    nonisolated static func documentPosition(
        for point: CGPoint, viewHeight: CGFloat, metrics: CellMetrics, grid: Grid,
        scrollOffset: Int, topInset: CGFloat
    ) -> SelectionPoint {
        let gridHeight = CGFloat(grid.rows) * metrics.cellHeight
        let gridTop =
            topInset + gridHeight <= viewHeight - TerminalLayout.insets.bottom
            ? topInset
            : viewHeight - TerminalLayout.insets.bottom - gridHeight
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
        at point: CGPoint, viewHeight: CGFloat, metrics: CellMetrics, grid: Grid,
        scrollOffset: Int, historyDepth: Int, topInset: CGFloat
    ) -> (scrollOffset: Int, head: SelectionPoint)? {
        let gridHeight = CGFloat(grid.rows) * metrics.cellHeight
        let gridTop =
            topInset + gridHeight <= viewHeight - TerminalLayout.insets.bottom
            ? topInset
            : viewHeight - TerminalLayout.insets.bottom - gridHeight
        let upward = point.y < gridTop
        let overshoot =
            upward
            ? gridTop - point.y
            : max(0, point.y - (gridTop + gridHeight))
        guard overshoot > 0 else { return nil }
        let rows = min(1 + Int(overshoot / (2 * metrics.cellHeight)), 8)
        let newOffset = min(max(0, scrollOffset + (upward ? rows : -rows)), max(0, historyDepth))
        guard newOffset != scrollOffset else { return nil }
        let head = documentPosition(
            for: point, viewHeight: viewHeight, metrics: metrics, grid: grid,
            scrollOffset: newOffset, topInset: topInset)
        return (scrollOffset: newOffset, head: head)
    }
}

extension TerminalSelection {
    /// Remembers the scrollback depth, so later output is accounted for.
    init(_ range: SelectionRange, grid: Grid) {
        self.init(
            start: GridPosition(row: range.start.row, column: range.start.column),
            end: GridPosition(row: range.end.row, column: range.end.column),
            baseScrollbackTotal: grid.scrollback.totalPushed)
    }
}
