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

/// What the pointer and the viewport need from the pane.
protocol PanePointerHost: AnyObject {
    var view: NSView { get }
    var session: TerminalSession! { get }
    var terminalView: TerminalView! { get }
    var terminalRenderer: TerminalRenderer! { get }
    var isOperable: Bool { get }
    var topInset: CGFloat { get }
    var verticalInsets: CGFloat { get }
    /// Rows above the live bottom.
    var scrollOffset: Int { get set }
    var selection: TerminalSelection? { get set }
    /// Output arrived while scrolled away, which the indicator says.
    var sawOutputWhileScrolled: Bool { get }
    var remote: PaneRemote { get }
    var commands: PaneCommands { get }
    func invalidateDisplay()
}

/// The pointer and the viewport in one pane: scrolling (wheel, keys and the
/// scroll-position pill), mouse selection and its auto-scroll, link hover
/// and opening, and `path:line` references followed to local files. Mouse
/// reporting is `TerminalView`'s; this is what happens when it is off or
/// overridden.
final class PanePointer: NSObject {
    weak var host: PanePointerHost?

    /// Cursor changes on transitions only: resetting the arrow every move
    /// fights the divider's resize cursor.
    var hoveringLink = false
    /// The last hover, replayed when a pending file check answers.
    var lastHover: (event: NSEvent, view: TerminalView)?
    /// What the last hover showed, kept while its answer is checked again.
    var lastHoverReference: OpenableReference?
    /// Injected so tests answer without the filesystem.
    var fileProbe = FileReferenceProbe.shared
    /// Underlined, so the target shows before a click opens it.
    var hoveredLink: TerminalSelection?
    var scrollPositionIndicator: ScrollPositionIndicator?
    /// What the selection's rows held when it was made, and which selection
    /// that was (`dropSelectionIfRewritten(in:)`).
    var selectionContent: (selection: TerminalSelection, content: SelectionContent)?

    /// The pane's view and session are being replaced: the pill and the
    /// hover belonged to the old ones.
    func reset() {
        selectionContent = nil
        scrollPositionIndicator?.removeFromSuperview()
        scrollPositionIndicator = nil
        hoveredLink = nil
        hoveringLink = false
    }

    init(host: PanePointerHost? = nil) {
        self.host = host
    }

    // The pane's state, read and written where the code that uses it reads
    // it best.
    var session: TerminalSession! { host?.session ?? nil }
    var terminalRenderer: TerminalRenderer! { host?.terminalRenderer ?? nil }
    var isOperable: Bool { host?.isOperable ?? false }
    var topInset: CGFloat { host?.topInset ?? 0 }
    var scrollOffset: Int {
        get { host?.scrollOffset ?? 0 }
        set { host?.scrollOffset = newValue }
    }
    var selection: TerminalSelection? {
        get { host?.selection }
        set { host?.selection = newValue }
    }
    var terminalView: TerminalView? { host?.terminalView ?? nil }
    func invalidateDisplay() { host?.invalidateDisplay() }

    /// The view's pointer hooks: the wheel, mouse reporting's questions,
    /// and the cell geometry the cursor rect, accessibility and the IME ask
    /// for.
    func install(on view: TerminalView) {
        view.onScroll = { [weak self] gesture in
            self?.scroll(gesture)
        }
        view.isMouseReportingEnabled = { [weak self] in
            self?.mouseReportingEnabled() ?? false
        }
        view.mouseTrackingMode = { [weak self] in
            self?.session?.sgrMouseTrackingMode ?? .off
        }
        view.mouseOverrideModifier = ConfigurationStore.shared.configuration.mouseOverrideModifier
        view.onMouseBytes = { [weak self, weak view] bytes in
            view?.noteUserInput()
            self?.session?.write(bytes)
        }
        view.cursorRectProvider = { [weak self] in
            guard let self, let session else { return nil }
            // One snapshot for both the cursor and the grid height: each takes
            // the session lock, against the reader, on the IME's caret query.
            let grid = session.snapshot()
            return cellRect(row: grid.cursor.row, column: grid.cursor.column, rows: grid.rows)
        }
        view.accessibilitySnapshotProvider = { [weak self] in
            guard let self, let session else { return nil }
            let grid = session.snapshot()
            dropSelectionIfRewritten(in: grid)
            return TerminalAccessibilitySnapshot(
                grid: grid,
                selection: selection.map { selectionRange(for: $0, in: grid) },
                scrollOffset: scrollOffset)
        }
        view.accessibilityCellFrameProvider = { [weak self] row, column in
            guard let self, let session else { return .zero }
            return cellRect(row: row, column: column, rows: session.snapshot().rows) ?? .zero
        }
        view.cellAtPoint = { [weak self] point in
            guard let self, let terminalRenderer, session != nil, let terminalView
            else { return (column: 0, row: 0) }
            let position = Self.documentPosition(
                for: point, viewHeight: terminalView.bounds.height,
                metrics: terminalRenderer.pointMetrics, grid: session.snapshot(), scrollOffset: 0,
                topInset: topInset)
            return (position.column, position.row)
        }
    }

    /// A screen cell's rect in the terminal view's coordinates.
    private func cellRect(row: Int, column: Int, rows: Int) -> CGRect? {
        guard let terminalRenderer, let terminalView else { return nil }
        return Self.cellFrame(row: row, column: column, viewHeight: terminalView.bounds.height,
            metrics: terminalRenderer.pointMetrics, rows: rows, topInset: topInset)
    }

    /// IME, accessibility and pointer hit testing share the renderer's anchor,
    /// including a grid that temporarily overflows during a live resize.
    nonisolated static func cellFrame(row: Int, column: Int, viewHeight: CGFloat,
        metrics: CellMetrics, rows: Int, topInset: CGFloat) -> CGRect {
        let rect = PaneFrameLoop.contentRect(in: CGSize(width: 0, height: viewHeight), scale: 1,
            gridHeight: CGFloat(rows) * metrics.cellHeight, topInset: topInset)
        return CGRect(x: TerminalLayout.insets.left + CGFloat(column) * metrics.cellWidth,
            y: rect.minY + CGFloat(row) * metrics.cellHeight,
            width: metrics.cellWidth, height: metrics.cellHeight)
    }

    // MARK: - Scrolling from the keyboard

    @objc func scrollHistoryPageUp(_: Any?) { scroll(.page(up: true)) }
    @objc func scrollHistoryPageDown(_: Any?) { scroll(.page(up: false)) }
    @objc func scrollHistoryToTop(_: Any?) { scroll(.toTop) }
    @objc func scrollHistoryToBottom(_: Any?) { scroll(.toBottom) }

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
            guard let host else { return }
            let usableHeight = host.view.bounds.height - host.verticalInsets
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

    /// ⌘A: scrollback plus screen.
    @objc func selectAll(_: Any?) {
        guard session != nil else { return }
        let grid = session.snapshot()
        setSelection(
            SelectionRange(
                start: SelectionPoint(row: -grid.scrollback.count, column: 0),
                end: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1)),
            in: grid)
    }

}

extension TerminalSelection {
    /// Remembers the scrollback depth, so later output is accounted for.
    init(_ range: SelectionRange, grid: Grid) {
        self.init(range, baseScrollbackTotal: grid.scrollback.totalPushed)
    }

    /// `range` as it was when `baseScrollbackTotal` lines had been pushed.
    init(_ range: SelectionRange, baseScrollbackTotal: Int) {
        self.init(
            start: GridPosition(row: range.start.row, column: range.start.column),
            end: GridPosition(row: range.end.row, column: range.end.column),
            baseScrollbackTotal: baseScrollbackTotal)
    }
}
