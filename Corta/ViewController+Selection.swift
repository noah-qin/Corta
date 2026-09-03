import Cocoa
import CortaTerminal

/// Selection and the viewport it is anchored to (Track C): scrolling, and
/// the mouse-mode query the view's mouse handlers consult.
extension ViewController {
    /// The core's ?1006 SGR mouse-reporting flag (M2.7). While off, clicks
    /// and the wheel keep their normal terminal behaviour.
    func mouseReportingEnabled() -> Bool {
        session?.isSgrMouseEncodingEnabled ?? false
    }

    func scroll(_ gesture: ScrollGesture) {

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
        // Scrolling moves the viewport without any grid output, so the
        // output flag alone would never trigger the redraw.
        invalidateDisplay()
    }
}

/// Mouse selection (M3.7) and copy (M3.8). The rules — what a word is, how a
/// soft-wrapped line copies — live in the core (`Selection.swift`); this
/// file is the AppKit side: events in, pasteboard out.
extension ViewController {
    // MARK: - Copy (M3.8)

    /// ⌘C and the Edit menu's Copy land here through the responder chain
    /// (`TerminalView` does not implement `copy:`). Copies the selection;
    /// with none there is nothing to do — ⌘C never reaches the PTY.
    @objc func copy(_ sender: Any?) {
        guard let selection, session != nil else { return }
        let grid = session.snapshot()
        let text = Selection.text(of: selectionRange(for: selection, in: grid), in: grid)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Confirmation *after* the write, and only when there was something
        // to write: an empty selection returns above, and a toast for a copy
        // that did not happen is worse than no toast. This is what makes
        // copy-on-select safe to have on by default (M7.10) — the clipboard
        // no longer changes silently.
        terminalView?.showToast(L10n.text("toast.copied"))
    }

    /// ⌘A: the whole document — scrollback plus screen.
    override func selectAll(_ sender: Any?) {
        guard session != nil else { return }
        let grid = session.snapshot()
        selection = TerminalSelection(
            start: GridPosition(row: -grid.scrollback.count, column: 0),
            end: GridPosition(row: grid.rows - 1, column: grid.columns - 1),
            baseScrollbackTotal: grid.scrollback.totalPushed)
        invalidateDisplay()
    }

    // MARK: - Mouse selection (M3.7)

    /// A left mouse down with mouse reporting off (the view checks that
    /// first — SGR reports keep precedence). Tracks the drag in a local
    /// event loop so the anchor and the gesture's unit never need storage:
    /// plain drag selects characters, double-click-drag words,
    /// triple-click-drag logical lines, shift-click extends the existing
    /// selection. A plain click without movement clears the selection.
    func handleSelectionMouseDown(_ event: NSEvent, in terminalView: TerminalView) {
        guard let window = terminalView.window, session != nil, terminalRenderer != nil
        else { return }
        var grid = session.snapshot()
        var anchor = documentPosition(for: event, in: terminalView, grid: grid)
        let extending = event.modifierFlags.contains(.shift)
        let unit: SelectionUnit
        switch event.clickCount {
        case 2: unit = .word
        case 3...: unit = .logicalLine
        default: unit = .character
        }

        if extending, unit == .character, let existing = selection {
            // Shift-click extends from whichever end of the current
            // selection is farther from the click.
            let current = selectionRange(for: existing, in: grid)
            anchor = anchor <= current.start ? current.end : current.start
        } else if unit == .character {
            // A plain click clears; a drag re-creates the selection below.
            selection = nil
            terminalView.noteAccessibilitySelectionChanged()
            invalidateDisplay()
        } else {
            applySelection(anchor: anchor, head: anchor, unit: unit, grid: grid)
        }

        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { continue }
            grid = session.snapshot()
            let head = documentPosition(for: next, in: terminalView, grid: grid)
            if next.type == .leftMouseUp {
                // The mouse-up lands the final range — except for a plain
                // click that never moved, which stays cleared.
                if head != anchor || unit != .character || extending {
                    applySelection(anchor: anchor, head: head, unit: unit, grid: grid)
                    // M7.10: a finished selection goes to the pasteboard when
                    // the user asked for that. On mouse-*up* only — copying
                    // on every intermediate drag position would rewrite the
                    // clipboard dozens of times per gesture.
                    if ConfigurationStore.shared.configuration.copyOnSelect { copy(nil) }
                } else {
                    // A click that never moved, with no modifier: in
                    // `link-activation = click` this is how a link opens
                    // (M7.9). Deferred to mouse-up precisely so that
                    // dragging across a URL still selects it.
                    openLinkOnPlainClick(next, in: terminalView)
                }
                break
            }
            if head != anchor || unit != .character {
                applySelection(anchor: anchor, head: head, unit: unit, grid: grid)
            }
        }
    }

    private func applySelection(
        anchor: SelectionPoint, head: SelectionPoint, unit: SelectionUnit, grid: Grid
    ) {
        let range = Selection.range(from: anchor, to: head, unit: unit, in: grid)
        selection = TerminalSelection(range, grid: grid)
        // A local change no output batch will report, so the accessibility
        // notification has to be posted from here.
        terminalView?.noteAccessibilitySelectionChanged()
        invalidateDisplay()
    }

    /// The selection as a core range against the current grid: rows recorded
    /// against `baseScrollbackTotal` shift by the number of lines pushed
    /// since (never negative — a cleared history leaves the rows stale, it
    /// does not move them onto other text).
    ///
    /// `totalPushed`, not `scrollback.count`: the count saturates at the
    /// ring's limit, and a selection anchored on it drifted off its text as
    /// soon as a full scrollback started evicting (M6.10).
    func selectionRange(for selection: TerminalSelection, in grid: Grid) -> SelectionRange {
        let range = SelectionRange(
            start: SelectionPoint(row: selection.start.row, column: selection.start.column),
            end: SelectionPoint(row: selection.end.row, column: selection.end.column))
        return range.shifted(
            byScrollbackGrowth: max(
                0, grid.scrollback.totalPushed - selection.baseScrollbackTotal))
    }

    /// The document position under an event: view point → grid cell, then
    /// viewport row → document row via the scroll offset.
    func documentPosition(for event: NSEvent, in terminalView: TerminalView, grid: Grid)
        -> SelectionPoint
    {
        Self.documentPosition(
            for: terminalView.convert(event.locationInWindow, from: nil),
            viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, grid: grid, scrollOffset: scrollOffset,
            topInset: topInset)
    }

    /// The pure half of the mapping, kept static and nonisolated so tests
    /// can exercise it without a window. Mirrors
    /// `contentRect(in:scale:gridHeight:)`: the grid is top-anchored when it
    /// fits (the rounding remainder lands at the bottom) and bottom-anchored
    /// mid-resize while it overflows (the top clips, the prompt stays).
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
}

extension TerminalSelection {
    /// Bridges a core range, remembering the scrollback depth it was taken
    /// against so output arriving later can be accounted for.
    init(_ range: SelectionRange, grid: Grid) {
        self.init(
            start: GridPosition(row: range.start.row, column: range.start.column),
            end: GridPosition(row: range.end.row, column: range.end.column),
            baseScrollbackTotal: grid.scrollback.totalPushed)
    }
}
