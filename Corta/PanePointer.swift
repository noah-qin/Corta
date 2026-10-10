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
    private var hoveringLink = false
    /// The last hover, replayed when a pending file check answers.
    private var lastHover: (event: NSEvent, view: TerminalView)?
    /// What the last hover showed, kept while its answer is checked again.
    private var lastHoverReference: OpenableReference?
    /// Injected so tests answer without the filesystem.
    var fileProbe = FileReferenceProbe.shared
    /// Underlined, so the target shows before a click opens it.
    private(set) var hoveredLink: TerminalSelection?
    private(set) var scrollPositionIndicator: ScrollPositionIndicator?

    /// The pane's view and session are being replaced: the pill and the
    /// hover belonged to the old ones.
    func reset() {
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
    private var session: TerminalSession! { host?.session ?? nil }
    private var terminalRenderer: TerminalRenderer! { host?.terminalRenderer ?? nil }
    private var isOperable: Bool { host?.isOperable ?? false }
    private var topInset: CGFloat { host?.topInset ?? 0 }
    private var scrollOffset: Int {
        get { host?.scrollOffset ?? 0 }
        set { host?.scrollOffset = newValue }
    }
    private var selection: TerminalSelection? {
        get { host?.selection }
        set { host?.selection = newValue }
    }
    private var terminalView: TerminalView? { host?.terminalView ?? nil }
    private func invalidateDisplay() { host?.invalidateDisplay() }

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
            guard let self, session != nil else { return nil }
            let cursor = session.snapshot().cursor
            return cellRect(row: cursor.row, column: cursor.column)
        }
        view.accessibilitySnapshotProvider = { [weak self] in
            guard let self, let session else { return nil }
            let grid = session.snapshot()
            return TerminalAccessibilitySnapshot(
                grid: grid,
                selection: selection.map { selectionRange(for: $0, in: grid) },
                scrollOffset: scrollOffset)
        }
        view.accessibilityCellFrameProvider = { [weak self] row, column in
            self?.cellRect(row: row, column: column) ?? .zero
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
    private func cellRect(row: Int, column: Int) -> CGRect? {
        guard let terminalRenderer else { return nil }
        let metrics = terminalRenderer.pointMetrics
        return CGRect(
            x: TerminalLayout.insets.left + CGFloat(column) * metrics.cellWidth,
            y: topInset + CGFloat(row) * metrics.cellHeight,
            width: metrics.cellWidth, height: metrics.cellHeight)
    }

    // MARK: - Scrolling from the keyboard

    @objc func scrollHistoryPageUp(_ sender: Any?) { scroll(.page(up: true)) }
    @objc func scrollHistoryPageDown(_ sender: Any?) { scroll(.page(up: false)) }
    @objc func scrollHistoryToTop(_ sender: Any?) { scroll(.toTop) }
    @objc func scrollHistoryToBottom(_ sender: Any?) { scroll(.toBottom) }

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
    @objc func selectAll(_ sender: Any?) {
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
                    if ConfigurationStore.shared.configuration.copyOnSelect { host?.commands.copy(nil) }
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

    /// Pure, for tests. Mirrors `PaneFrameLoop.contentRect(in:scale:gridHeight:topInset:)`:
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

    var opensLinksOnPlainClick: Bool {
        ConfigurationStore.shared.configuration.linkActivation == .click
    }

    /// ⌘-click opens and consumes; anything else falls through to mouse
    /// reporting or selection. Plain clicks: `openLinkOnPlainClick`.
    func handleLinkClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        // A `path:line`, local or remote. URLs win; the detectors don't
        // overlap in practice, and the order makes that explicit.
        return openReference(under: event, in: terminalView)
    }

    /// `link-activation = click` on mouse-up, for a click that never moved.
    @discardableResult
    func openLinkOnPlainClick(_ event: NSEvent, in terminalView: TerminalView) -> Bool {
        guard opensLinksOnPlainClick, !event.modifierFlags.contains(.shift)
        else { return false }
        if let link = linkUnder(event, in: terminalView) { return open(link) }
        return openReference(under: event, in: terminalView)
    }

    /// Re-checks the scheme at the boundary where output launches another
    /// app (`SECURITY.md` §2.4).
    private func open(_ link: LinkDetection.Link) -> Bool {
        guard let url = Self.target(of: link.url) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// The URL a link opens, and so the one its tooltip names: allowlisted
    /// scheme, host in IDNA form, anything invisible percent-encoded, and no
    /// userinfo. Shown raw, `https://аpple.com` read as Apple while opening
    /// `xn--pple-43d.com`, and `https://github.com@evil.example` named the
    /// wrong host first; the destination is what `SECURITY.md` §2.4 says to show.
    nonisolated static func target(of raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Hand cursor, underline and a tooltip with the real target
    /// (`SECURITY.md` §2.4), on mouse-moved and ⌘ changes. The cursor changes
    /// on transitions only, or it flickers against `NSSplitView`'s resize
    /// cursor.
    func handleLinkHover(_ event: NSEvent, in terminalView: TerminalView) {
        if lastHover?.event !== event { lastHover = nil }
        // The underline must mean "this will open".
        let armed = opensLinksOnPlainClick || event.modifierFlags.contains(.command)
        if session != nil, let link = linkUnder(event, in: terminalView) {
            if armed, !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            } else if !armed, hoveringLink {
                NSCursor.arrow.set()
                hoveringLink = false
            }
            let target = Self.target(of: link.url)?.absoluteString ?? ""
            let tip = opensLinksOnPlainClick
                ? target : L10n.format("link.commandClick", target)
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(armed ? link.range : nil)
        } else if armed, session != nil,
            let reference = hoverReference(event, in: terminalView)
        {
            if !hoveringLink {
                NSCursor.pointingHand.set()
                hoveringLink = true
            }
            let tip: String
            switch reference {
            case .local(let local):
                // The path and the required editor setting.
                let target = "\(local.url.path):\(local.line)"
                tip = ConfigurationStore.shared.configuration.openFileCommand.isEmpty
                    ? L10n.format("link.fileNoLine", target) : target
            case .remote(let remote):
                // Host and path, and that a managed copy opens.
                tip = L10n.format(
                    "link.remoteFile", "\(remote.host):\(remote.remotePath):\(remote.line)")
            }
            if terminalView.toolTip != tip { terminalView.toolTip = tip }
            setHoveredLink(reference.range)
        } else {
            resetLinkHover(terminalView)
        }
    }

    /// The reference under a hover, if known now. A local path still being
    /// checked shows nothing yet; its answer replays the hover, if the
    /// pointer has not moved on.
    private func hoverReference(_ event: NSEvent, in terminalView: TerminalView) -> OpenableReference? {
        let detected = detectedReferenceUnder(event, in: terminalView)
        switch lookUpReference(detected) {
        case .resolved(let reference):
            lastHoverReference = reference
            return reference
        case .pending(let path):
            // The same reference still under the pointer as its answer ages
            // out: keep showing it while it is checked again, or the
            // underline flickered every `lifetime`.
            if let last = lastHoverReference, let detected, last.range == detected.range {
                fileProbe.probe(path) { _ in }
                return last
            }
            lastHover = (event, terminalView)
            fileProbe.probe(path) { [weak self] _ in
                guard let self, let hover = self.lastHover, hover.event === event else { return }
                self.handleLinkHover(hover.event, in: hover.view)
            }
            return nil
        }
    }

    /// Resets hover state, only if the hand is up.
    func resetLinkHover(_ terminalView: TerminalView) {
        if hoveringLink {
            NSCursor.arrow.set()
            hoveringLink = false
        }
        if terminalView.toolTip != nil { terminalView.toolTip = nil }
        if hoveredLink != nil {
            hoveredLink = nil
            invalidateDisplay()
        }
    }

    private func setHoveredLink(_ range: SelectionRange?) {
        guard session != nil else { return }
        let highlight = range.map { TerminalSelection($0, grid: session.snapshot()) }
        guard !Self.sameRange(hoveredLink, highlight) else { return }
        hoveredLink = highlight
        invalidateDisplay()
    }

    private static func sameRange(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.start == b.start && a.end == b.end
            && a.baseScrollbackTotal == b.baseScrollbackTotal
    }

    /// Through the same mapping selection uses.
    private func linkUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> LinkDetection.Link?
    {
        guard session != nil, terminalRenderer != nil else { return nil }
        let grid = session.snapshot()
        let point = documentPosition(for: event, in: terminalView, grid: grid)
        // A link that cannot open — an OSC 8 `ftp:` or `file:` target — is no
        // link: no hand, no underline, and no tooltip showing its raw text.
        guard let link = LinkDetection.link(at: point, in: grid), Self.target(of: link.url) != nil
        else { return nil }
        return link
    }

    /// A reference known to name an existing local file.
    struct ResolvedFileReference: Equatable {
        var url: URL
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves a reference against a directory, or refuses. Pure, with the
    /// filesystem check injected.
    ///
    /// - Parameter directory: the pane's local working directory. Nil (remote
    ///   or unreported) refuses even absolute paths, which name remote files
    ///   there too.
    static func resolve(
        _ reference: FileReferenceDetection.Reference, directory: String?,
        isRegularFile: (String) -> Bool = PathProbe.isRegularFile
    ) -> ResolvedFileReference? {
        guard let path = candidatePath(reference, directory: directory), isRegularFile(path)
        else { return nil }
        return resolved(reference, at: path)
    }

    /// The absolute path a reference names from `directory`, before any
    /// filesystem check; nil without a local directory.
    nonisolated static func candidatePath(
        _ reference: FileReferenceDetection.Reference, directory: String?
    ) -> String? {
        guard let directory else { return nil }
        let expanded = (reference.path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/")
            ? expanded
            : (directory as NSString).appendingPathComponent(expanded)
        // Resolves `..`, so the path checked is the path opened. Not a sandbox:
        // the shell can read anything the user can.
        return (absolute as NSString).standardizingPath
    }

    private nonisolated static func resolved(
        _ reference: FileReferenceDetection.Reference, at path: String
    ) -> ResolvedFileReference {
        ResolvedFileReference(
            url: URL(fileURLWithPath: path), line: reference.line,
            column: reference.column, range: reference.range)
    }

    /// What a detected `path:line` opens: the local file it names, else the
    /// remote host's. One detection serves both — the pattern scan runs on the
    /// main thread, and it ran twice per ⌘ press over text that matched nothing.
    enum OpenableReference {
        case local(ResolvedFileReference)
        case remote(PaneRemote.ResolvedReference)

        var range: SelectionRange {
            switch self {
            case .local(let reference): reference.range
            case .remote(let reference): reference.range
            }
        }
    }

    /// What a detected reference opens, as far as is known without blocking:
    /// whether a local path is a file comes from `FileReferenceProbe`, off the
    /// main thread — a `stat` here, per mouse move, froze the app on a mount
    /// that stopped answering. `pending` is a path still being checked.
    enum ReferenceLookup {
        case resolved(OpenableReference?)
        case pending(path: String)
    }

    func lookUpReference(_ detected: FileReferenceDetection.Reference?) -> ReferenceLookup {
        guard let detected else { return .resolved(nil) }
        if let path = Self.candidatePath(detected, directory: session.workingDirectory) {
            switch fileProbe.cached(path) {
            case true?: return .resolved(.local(Self.resolved(detected, at: path)))
            case nil: return .pending(path: path)
            case false?: break
            }
        }
        return .resolved(host?.remote.resolve(detected).map(OpenableReference.remote))
    }

    /// Opens what is under `event` once the local check has answered; the
    /// click is taken either way, since it named a reference.
    private func openReference(under event: NSEvent, in terminalView: TerminalView) -> Bool {
        let detected = detectedReferenceUnder(event, in: terminalView)
        if case .resolved(nil) = lookUpReference(detected) { return false }
        openDetected(detected)
        return true
    }

    /// Opens what `detected` names, once a pending local check has answered;
    /// `otherwise` runs when it names nothing that opens.
    func openDetected(
        _ detected: FileReferenceDetection.Reference?, otherwise: @escaping () -> Void = {}
    ) {
        switch lookUpReference(detected) {
        case .resolved(let reference?):
            open(reference)
        case .resolved(nil):
            otherwise()
        case .pending(let path):
            fileProbe.probe(path) { [weak self] _ in
                guard let self else { return }
                if case .resolved(let reference?) = self.lookUpReference(detected) {
                    self.open(reference)
                } else {
                    otherwise()
                }
            }
        }
    }

    @discardableResult
    func open(_ reference: OpenableReference) -> Bool {
        switch reference {
        case .local(let local): open(local)
        case .remote(let remote): host?.remote.open(remote) ?? false
        }
    }

    /// Detection before resolution, shared with the remote path
    /// (`PaneRemote.resolve`).
    func detectedReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> FileReferenceDetection.Reference?
    {
        guard isOperable, let terminalRenderer else { return nil }
        let grid = session.snapshot()
        let point = Self.documentPosition(
            for: terminalView.convert(event.locationInWindow, from: nil),
            viewHeight: terminalView.bounds.height, metrics: terminalRenderer.pointMetrics,
            grid: grid, scrollOffset: scrollOffset, topInset: topInset)
        return FileReferenceDetection.reference(at: point, in: grid)
    }

    @discardableResult
    func open(_ reference: ResolvedFileReference) -> Bool {
        let opened = Self.openFileAt(
            url: reference.url, line: reference.line, column: reference.column)
        if !opened {
            terminalView?.showToast(L10n.text("toast.badOpenFileCommand"), kind: .warning)
        }
        return opened
    }

    /// Opens a local file, at the line if the configured command takes one;
    /// shared by local references and `RemoteEditCoordinator`'s managed
    /// copies. Output-derived files require `open-file-command`: a default
    /// application can execute a .command or .terminal file. Runs via `Process` with
    /// separate arguments, **never a shell**, which would revive the path's
    /// metacharacters (`SECURITY.md` §2.3).
    @discardableResult
    static func openFileAt(url: URL, line: Int, column: Int?, command: String? = nil) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false, command: command)
    }

    /// Remote bytes must go to an explicitly configured editor, never to a
    /// LaunchServices handler that could execute a .command or .terminal file.
    static func openRemoteFileAt(url: URL, line: Int, column: Int?) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false)
    }

    static func openFileAt(
        url: URL, line: Int, column: Int?, allowsDefaultApplication: Bool,
        command: String? = nil
    ) -> Bool {
        let template = command ?? ConfigurationStore.shared.configuration.openFileCommand
        guard !template.isEmpty else {
            guard allowsDefaultApplication else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
        let arguments = openFileArguments(
            template: template, path: url.path, line: line, column: column)
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            // Absolute only: a bare name would resolve through the shell's PATH.
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// The last reference in `record`'s output, walking backwards: closest to
    /// where a build tool says what went wrong. Bounded in rows scanned, and a
    /// line longer than a hover may scan is skipped unjoined, so a huge log
    /// without one isn't a full scan on the main thread — menu validation
    /// runs this.
    func detectedReferenceInCommand(_ record: CommandRecord?)
        -> FileReferenceDetection.Reference?
    {
        guard let record, isOperable else { return nil }
        let start = record.outputStartRow ?? record.promptRow + 1
        let grid = session.snapshot()
        let base = grid.scrollback.totalPushed
        let end = record.endRow ?? grid.absoluteRow(ofScreenRow: grid.cursor.row)
        let startDoc = start - base
        var row = end - base - 1
        var rowsScanned = 0
        while row >= startDoc, rowsScanned < Self.maxCommandOutputRowsScanned {
            let line = FileReferenceDetection.references(inLineContaining: row, in: grid)
            rowsScanned += row - line.firstRow + 1
            if let reference = line.references.last { return reference }
            row = line.firstRow - 1
        }
        return nil
    }

    private static let maxCommandOutputRowsScanned = 2000

    /// Substitutes `{file}`, `{line}` and `{column}` per argument, splitting the
    /// user's template before substitution so a path with spaces stays one
    /// argument. Pure and `nonisolated`.
    nonisolated static func openFileArguments(
        template: String, path: String, line: Int, column: Int?
    ) -> [String] {
        let values = ["{file}": path, "{line}": String(line), "{column}": String(column ?? 1)]
        // One pass over the template's own text: replaced one after another, a
        // file named `a{line}` became `a12` — a different file from the one
        // checked to exist, and remote names are the server's to choose.
        return template.split(whereSeparator: \.isWhitespace).map { part in
            var result = ""
            var rest = part[...]
            while !rest.isEmpty {
                if let (token, value) = values.first(where: { rest.hasPrefix($0.key) }) {
                    result += value
                    rest = rest.dropFirst(token.count)
                } else {
                    result.append(rest.removeFirst())
                }
            }
            return result
        }
    }

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
