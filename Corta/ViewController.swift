//
//  ViewController.swift
//  Corta
//
//  Created by Noah on 9/1/26.
//

import Cocoa
import CoreText
import CortaTerminal
import Metal
import Synchronization

/// Owns one `TerminalSession` and the `TerminalRenderer`/`TerminalView` that
/// draw it — the pane. A window composes panes through
/// `SplitViewController` and its `SplitTree` (M5); nothing here knows about
/// sibling panes beyond the `splitController` back-reference (`DESIGN.md`
/// §2.4).
///
/// This file owns lifecycle, the session and the render loop. Behaviour
/// lives in extensions by concern: `ViewController+Input.swift` (Track A),
/// `ViewController+Selection.swift` (Track C) and
/// `ViewController+Commands.swift` (Track D).
class ViewController: NSViewController {
    // Not `private`: the extension files (`+Input`, `+Selection`, `+Commands`)
    // reach these, and extensions cannot add their own storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    private var commandQueue: MTLCommandQueue!
    /// Kept so `ViewController+Commands` can rebuild the renderer (with a new
    /// font size) without going through `MTLCreateSystemDefaultDevice` again.
    var device: MTLDevice!
    /// The font's point size; ⌘+/⌘−/⌘0 change it (`ViewController+Commands`).
    /// The atlas is rasterised for one size, so a change rebuilds the
    /// renderer — see `setFontSize`.
    var fontSize: CGFloat = ViewController.defaultFontSize
    /// Matches the stock 120x30 Terminal profile on this Mac. Keeping the
    /// terminal's default here (rather than compensating with narrower cell
    /// geometry) preserves the font's real advance and makes TUIs such as
    /// Claude Code occupy the same physical proportions in both apps.
    static let defaultFontSize: CGFloat = 12
    /// Set before the view loads when the pane is created by a split (M5):
    /// the focused pane's OSC 7 directory (M5.5), and the grid size the new
    /// pane will actually hold, so the shell's first output is laid out
    /// against the right width rather than the default and then reflowed.
    var inheritedWorkingDirectory: String?
    var initialGridSize: TerminalSize?
    var scrollOffset = 0
    /// True while the pointing-hand cursor is up for a ⌘-hovered link
    /// (M4.6). Cursor changes happen on transitions only — setting the
    /// arrow on every mouse-moved fights the split view's resize cursor
    /// near a divider and makes the pointer flicker there (M5).
    var hoveringLink = false
    /// The current text selection, owned by `ViewController+Selection.swift`
    /// (Track C) and read by the render loop. Stored here because extensions
    /// cannot add storage.
    var selection: TerminalSelection?
    /// The unfocused-pane dim (M5.2): a translucent wash over the pane, so
    /// which pane owns the keyboard is visible at a glance — the hidden
    /// cursor alone was too subtle. Above the terminal canvas, below the
    /// search bar's glass; it never intercepts input (`PassthroughView`).
    var focusDimView: NSView?
    /// The focus state last reported to the child (`?1004`, M6.7). `nil`
    /// until the first report, so the first one always goes out. Storage
    /// lives here because `ViewController+Focus` is an extension.
    var lastReportedFocus: Bool?
    /// Set by `SplitViewController` once the window's style mask and content
    /// size are final — the gate that keeps transient startup layouts from
    /// reaching the child (see `resizeSessionToFitView`).
    var didSizeWindow = false
    /// Set by layout changes the damage diff cannot see (drawable size,
    /// backing scale) and by local actions that change what is drawn without
    /// touching the grid (scrolling); consumed by `updateDamage`.
    private var needsRedraw = true
    /// True while a synchronized-output batch (`?2026`, M4.3) has withheld a
    /// frame that would otherwise have been presented; forces the next
    /// non-synchronized `updateDamage` to present once, even if the diff
    /// alone finds nothing new since the mode ended.
    private var wasSynchronizedOutputActive = false
    /// Set from the reader thread's `onOutput` (every parse batch); the
    /// vsync gate checks this one flag and only snapshots and diffs the grid
    /// when it is set, so a truly idle frame costs a boolean check rather
    /// than a line-by-line comparison.
    private let outputPending = Mutex(false)
    /// Coalesces `session.resize` during a live drag (M2.9); the last size
    /// actually requested, so no-op layouts don't re-send the same winsize.
    private var resizeDebouncer: ResizeDebouncer!
    /// The last grid size sent (or about to be sent) to the child; ⌘+/⌘−
    /// re-fit the window to keep this grid size at the new cell metrics.
    var lastRequestedSize: TerminalSize?

    // Search (M4.4), owned by `ViewController+Search.swift`. Storage lives
    // here because extensions cannot add their own.

    /// The Liquid Glass search bar; `nil` when closed.
    var searchBar: NSGlassEffectView?
    var searchBarContainer: NSGlassEffectContainerView?
    var searchField: NSTextField?
    /// Every current match, oldest first — recomputed on each query or grid
    /// change, not incrementally maintained.
    var searchMatches: [SelectionRange] = []
    var currentSearchMatchIndex: Int?
    /// The scroll position from before the search bar opened, restored on
    /// Esc.
    var scrollOffsetBeforeSearch: Int?
    /// Local key monitor for Esc while the bar is open: the field editor
    /// turns Esc into `cancelOperation:`, which NSSearchField can swallow
    /// without ever calling the delegate — a monitor sees the key before
    /// any of that. Removed when the bar closes.
    var searchKeyMonitor: Any?

    /// The drag is over — the child should see the final size now, not after
    /// the debounce window expires. Wired to `TerminalView`'s
    /// `viewDidEndLiveResize` (live-resize notifications live on the view).
    func endLiveResize() {
        resizeDebouncer.flush()
    }

    /// Initial and minimum grid sizes. The window's content size is derived
    /// from these and the font's cell metrics, never from hardcoded points,
    /// so it follows a font or size change.
    private let defaultColumns = 120
    private let defaultRows = 30
    /// Titlebar plus, when the window is tabbed, the tab bar. AppKit
    /// reports the pair as the difference between the frame and the content
    /// layout rect, which is the only value that follows a tab bar
    /// appearing. Before the window exists, the titlebar alone is the best
    /// estimate.
    var windowChrome: CGFloat {
        guard let window = view.window else { return TerminalLayout.titlebarHeight }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }
    /// Distance from the top of the drawable to the first row. Per pane:
    /// only a pane touching the window's top edge sits under the chrome
    /// (titlebar, traffic lights), so each pane pays the chrome share that
    /// actually overlaps it and just its own inset otherwise (M5 — a
    /// bottom-row pane has no titlebar above it).
    var topInset: CGFloat {
        guard let window = view.window else {
            return TerminalLayout.titlebarHeight + TerminalLayout.insets.top
        }
        let distanceFromTop = window.frame.height - view.convert(view.bounds, to: nil).maxY
        return TerminalLayout.insets.top + max(0, windowChrome - distanceFromTop)
    }
    /// Total vertical space the grid does not get.
    var verticalInsets: CGFloat { topInset + TerminalLayout.insets.bottom }

    /// The window-level split controller owning this pane (M5). Panes are
    /// always its children in the app; nil only for a detached controller.
    var splitController: SplitViewController? { parent as? SplitViewController }
    /// Keyboard input, the window title and the cursor belong to the
    /// focused pane alone (M5.2); the unfocused panes draw without a
    /// cursor, which doubles as the focus indicator.
    var isFocusedPane: Bool { splitController?.focusedPane === self }

    let minimumColumns = 20
    let minimumRows = 5

    /// The smallest pixel area the pane tolerates, at the current cell
    /// metrics — the leaf value of the split tree's minimum-size walk
    /// (M5.4).
    var minimumContentSize: CGSize {
        let metrics = terminalRenderer.pointMetrics
        return CGSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + TerminalLayout.insetHeight)
    }

    /// The grid size that fits a pixel area, using the current cell metrics
    /// and this pane's insets — how a split predicts the new pane's winsize
    /// before layout settles it exactly.
    func gridSize(fitting size: CGSize) -> TerminalSize {
        let metrics = terminalRenderer.pointMetrics
        return TerminalSize(
            rows: UInt16(max(1, (size.height - verticalInsets) / metrics.cellHeight)),
            columns: UInt16(max(1, (size.width - TerminalLayout.insetWidth) / metrics.cellWidth)))
    }

    /// The window size that fits the initial grid exactly. With
    /// `.fullSizeContentView` the pane area spans the whole frame — and
    /// `setContentSize` sizes the frame on this OS — so this is the *frame*
    /// size: grid cells plus this pane's insets and the measured chrome.
    /// The first pane's pre-layout frame and the window's initial sizing
    /// both derive from it, so the session is born at its final size.
    var initialWindowContentSize: NSSize {
        let metrics = terminalRenderer.pointMetrics
        let grid = initialGridSize
            ?? TerminalSize(rows: UInt16(defaultRows), columns: UInt16(defaultColumns))
        return NSSize(
            width: CGFloat(grid.columns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(grid.rows) * metrics.cellHeight + verticalInsets)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let font = TerminalFont.primary(ofSize: fontSize)
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is required")
        }
        self.device = device
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        terminalRenderer = try! TerminalRenderer(device: device, font: font, scale: scale)
        commandQueue = device.makeCommandQueue()

        let contentSize = initialWindowContentSize
        // Size the container to the target content size *before* the first
        // layout. Otherwise the storyboard's 480x270 produces a transient
        // 53x15 session, the shell's early output is laid out against that,
        // and growing the window afterwards leaves that output stranded in
        // the top half with fifteen blank rows below it.
        self.view.setFrameSize(contentSize)

        let view = TerminalView(frame: NSRect(origin: .zero, size: contentSize))
        // Deliberately no autoresizing mask. The mask applies the superview's
        // resize *delta*, and this view is born at the target content size
        // while the storyboard's view is still its own smaller size. The
        // `setContentSize` in `viewDidAppear` then grew the superview by
        // (240, 138) and the mask added that delta on top of a view already
        // at the target — leaving it 960x546 inside a 720x408 superview.
        //
        // In AppKit's bottom-left coordinates the overflow sits above the
        // visible content, so row 0 — the only row with anything on it in a
        // fresh shell — was drawn entirely inside the clipped strip and the
        // window looked black. `viewDidLayout` sets the frame outright.
        // The terminal canvas is the CONTENT layer, and content layers are
        // opaque. Liquid Glass belongs to the navigation and control layer —
        // a small surface floating *over* content, refracting what is behind
        // it. Wrapping the whole canvas in `NSGlassEffectView` used it the
        // wrong way round: there was nothing underneath worth refracting, and
        // the material's own light raised the background's luminance, costing
        // every colour about a fifth of its contrast ratio. The glass now
        // lives where it is meant to — see `ViewController+Search`.
        self.view.addSubview(view)
        // Constraints, not a frame set from a layout callback. The view is
        // born at the target content size while the storyboard's view is
        // still its own smaller size, and `viewWillAppear`'s `setContentSize`
        // then grows the superview — but a frame assigned in `viewDidLayout`
        // only tracks if that callback runs again afterwards, which it did
        // not: the view stayed 480x270 inside a 1080x510 superview, so the
        // drawable was half size and the grid came out 53x15 instead of
        // 120x30. AppKit maintains constraints regardless of callback order.
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        terminalView = view

        let dim = PassthroughView()
        // Layer-backed: a subview without a backing layer never composites
        // over the Metal layer and the dim would be silently invisible.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dim.isHidden = true
        dim.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(dim)
        NSLayoutConstraint.activate([
            dim.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            dim.topAnchor.constraint(equalTo: self.view.topAnchor),
            dim.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        focusDimView = dim

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let initialSize = initialGridSize
            ?? TerminalSize(rows: UInt16(defaultRows), columns: UInt16(defaultColumns))
        session = try! TerminalSession(
            executable: shell, arguments: ["-l"],
            // Launched from Finder the app inherits "/" as its working
            // directory, so the shell opened in the filesystem root. A
            // terminal should start where a login shell would — and a split
            // pane starts where the pane it was split from is (M5.5).
            size: initialSize,
            workingDirectory: inheritedWorkingDirectory ?? NSHomeDirectory())
        lastRequestedSize = initialSize
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session.resize(to: size)
        }
        // Fires on the reader thread after every parse batch.
        observeWindowFocus()
        session.onOutput = { [weak self] in
            self?.noteOutput()
        }

        view.onRenderFrame = { [weak self] pass, drawableSize, drawable in
            self?.render(into: pass, drawableSize: drawableSize, drawable: drawable)
        }
        view.shouldRenderFrame = { [weak self] in
            self?.updateDamage() ?? false
        }
        view.onKeyBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        view.onScroll = { [weak self] gesture in
            self?.scroll(gesture)
        }
        view.onLiveResizeEnded = { [weak self] in
            self?.endLiveResize()
        }
        view.onBackingScaleChange = { [weak self] scale in
            self?.rebuildAtlas(forBackingScale: scale)
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
        view.onSearchKey = { [weak self] (event: NSEvent) -> Bool in
            self?.handleSearchKey(event) ?? false
        }
        view.cellSize = CGSize(width: terminalRenderer.pointMetrics.cellWidth, height: terminalRenderer.pointMetrics.cellHeight)
        // The preedit overlay draws with the renderer's own font stack at
        // the current size, so ⌘=/⌘- resizes marked text too.
        view.preeditFontProvider = { [weak self] in
            guard let self else {
                return NSFont.monospacedSystemFont(
                    ofSize: ViewController.defaultFontSize, weight: .medium)
            }
            return TerminalFont.primary(ofSize: fontSize) as NSFont
        }
        view.isMouseReportingEnabled = { [weak self] in
            self?.mouseReportingEnabled() ?? false
        }
        view.onMouseBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        // Click-to-focus, ⌘⌥ arrows, split and close all converge on
        // `makeFirstResponder`; this is how the split controller learns
        // which pane owns input (M5.2).
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.splitController?.noteFocus(self)
        }
        // Track A's IME layer positions the candidate window and the preedit
        // overlay from this: the cursor cell's rect in view coordinates,
        // derived here where the insets and metrics live.
        view.cursorRectProvider = { [weak self] in
            guard let self, let terminalRenderer, session != nil else { return nil }
            let metrics = terminalRenderer.pointMetrics
            let cursor = session.snapshot().cursor
            return CGRect(
                x: TerminalLayout.insets.left + CGFloat(cursor.column) * metrics.cellWidth,
                y: topInset + CGFloat(cursor.row) * metrics.cellHeight,
                width: metrics.cellWidth, height: metrics.cellHeight)
        }
        // SGR mouse reports name an on-screen cell, so they need the same
        // inset-aware, bottom-anchored mapping as selection hit-testing
        // (`documentPosition`) — a raw divide of the view point by the cell
        // size reports a cell off by the insets. scrollOffset is 0 here:
        // the report is about what is on screen, not the document.
        view.cellAtPoint = { [weak self] point in
            guard let self, let terminalRenderer, session != nil, let terminalView
            else { return (column: 0, row: 0) }
            let grid = session.snapshot()
            let position = Self.documentPosition(
                for: point, viewHeight: terminalView.bounds.height,
                metrics: terminalRenderer.pointMetrics, grid: grid, scrollOffset: 0,
                topInset: self.topInset)
            return (position.column, position.row)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Layout can change the drawable's size or backing scale without any
        // grid change the damage diff would notice — force one frame.
        invalidateDisplay()
        resizeSessionToFitView()
    }

    /// Runs at vsync before a drawable is acquired. Cheap path: nothing
    /// arrived and nothing local changed, so no snapshot, no diff, no frame —
    /// and the display link parks itself (`TerminalView.frameTick`), which is
    /// what lets a static screen idle at ~0% CPU (`PERFORMANCE.md` §3). When
    /// output did arrive, the snapshot is diffed against the renderer's
    /// line-granular cache and the frame happens only on damage.
    private func updateDamage() -> Bool {
        if session.takeBell() {
            handleBell()
        }
        let hasOutput = outputPending.withLock { pending -> Bool in
            let was = pending
            pending = false
            return was
        }
        guard needsRedraw || hasOutput else { return false }
        // The OSC 0/2 title (M2.8) arrives as output; applying it here keeps
        // the window — and with native tabbing (M4.7), the tab label —
        // current without a timer. The window's title is the focused
        // pane's (M5.2); an unfocused pane's title applies when it takes
        // focus (`SplitViewController.noteFocus`).
        if hasOutput, isFocusedPane, let title = session.windowTitle, let window = view.window,
            window.title != title
        {
            window.title = title
        }
        // While the search bar is open, output shifts what matches: re-run
        // the query against the new snapshot before this frame diffs it
        // (M4.4). Recomputed, not patched — `updateSearchResults` explains.
        if hasOutput, searchBar != nil {
            updateSearchResults(scrollsToMatch: false)
        }
        if session.isSynchronizedOutputEnabled {
            // A frame drawn mid-batch would show a torn intermediate state.
            // Remember that a present is owed and wait for the matching
            // DECRST, which arrives as its own output batch and forces one
            // frame then (`?2026`, M4.3).
            wasSynchronizedOutputActive = true
            return false
        }
        let forced = needsRedraw || wasSynchronizedOutputActive
        needsRedraw = false
        wasSynchronizedOutputActive = false
        let grid = session.snapshot()
        // The rebuilt rows land in the renderer's cache; `render` diffs once
        // more when it draws and picks up anything that arrived since.
        let damaged = terminalRenderer.updateInstances(
            grid: grid, scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0 && isFocusedPane, selection: selection,
            searchMatches: searchMatches.map { TerminalSelection($0, grid: grid) },
            currentSearchMatchIndex: currentSearchMatchIndex)
        return forced || damaged
    }

    /// M4.8, app side — dispatches on `BellMode.current`. The core decided
    /// nothing beyond "a bell happened" (`Terminal.takeBell()`).
    private func handleBell() {
        switch BellMode.current {
        case .audible:
            NSSound.beep()
        case .visual:
            terminalView.flashBell()
        case .muted:
            break
        }
    }

    /// Called from the reader thread after each parse batch: record that the
    /// grid may have changed and wake the (possibly parked) display link.
    nonisolated private func noteOutput() {
        outputPending.withLock { $0 = true }
        Task { @MainActor [weak self] in
            self?.terminalView.setNeedsRedraw()
        }
    }

    /// Marks the display dirty and wakes the display link — for local changes
    /// (layout, scrolling) that produce no PTY output.
    func invalidateDisplay() {
        needsRedraw = true
        terminalView.setNeedsRedraw()
    }

    func resizeSessionToFitView() {
        // Nothing reaches the child until `SplitViewController` has made the
        // window's style mask final (`.fullSizeContentView` decides how tall
        // the content view is) and pinned the content size — before that,
        // layouts run at transient sizes the child's early output would be
        // laid out against (D.1: a 28-row transient followed by the real 30
        // stranded two blank rows under the prompt). The session is
        // constructed at the target size already, so skipping early layouts
        // loses nothing.
        //
        // The style-mask insertion lands one layout pass late: the first
        // layout after `setContentSize` still runs at the content-rect
        // height (frame minus titlebar — observed 522pt against the final
        // 554pt), and delivering that size shrinks the grid and strands
        // content exactly as above. That check runs one level up now
        // (`SplitViewController.sizeSettled`): a pane in a split tree
        // legitimately does not fill its window's frame, so it cannot run
        // the check against its own bounds — the content view always fills
        // the frame, split or not (M5) — and the one-time frame correction
        // for the `setContentSize` chrome mismeasurement must have run too.
        guard didSizeWindow, session != nil, let terminalRenderer, view.window != nil,
            let splitController, splitController.sizeSettled
        else { return }
        let usable = CGSize(
            width: view.bounds.width - TerminalLayout.insetWidth,
            height: view.bounds.height - verticalInsets)
        let columns = UInt16(max(1, usable.width / terminalRenderer.pointMetrics.cellWidth))
        let rows = UInt16(max(1, usable.height / terminalRenderer.pointMetrics.cellHeight))
        let size = TerminalSize(rows: rows, columns: columns)
        guard size != lastRequestedSize else { return }
        lastRequestedSize = size
        // Always coalesced to the trailing edge of a resize stream: window
        // drags, divider drags and the zoom animation all fire per-frame
        // layouts, and each immediate delivery would rewrap the grid
        // mid-gesture — the visible "text jumps" (M2.9, M5.4). The initial
        // size needs no delivery at all: the session is born at it and the
        // startup gate (`sizeSettled`) holds back the transient frames.
        resizeDebouncer.resize(to: size, coalesce: true)
    }

    /// Runs at vsync, on the main thread — reads the latest grid without
    /// ever blocking the reader thread (`PERFORMANCE.md` §2.1).
    private func render(
        into renderPassDescriptor: MTLRenderPassDescriptor, drawableSize: CGSize, drawable: CAMetalDrawable
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let grid = session.snapshot()
        terminalRenderer.render(
            grid: grid, scrollOffset: scrollOffset,
            rect: Self.contentRect(
                in: drawableSize, scale: terminalRenderer.scale,
                gridHeight: CGFloat(grid.rows) * terminalRenderer.metrics.cellHeight,
                topInset: topInset),
            drawableSize: drawableSize,
            cursorVisible: scrollOffset == 0 && isFocusedPane, selection: selection,
            searchMatches: searchMatches.map { TerminalSelection($0, grid: grid) },
            currentSearchMatchIndex: currentSearchMatchIndex,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The grid's rectangle inside the drawable, in pixels.
    ///
    /// Pixel space has its origin at the drawable's top-left
    /// (`Shaders.metal`). When the grid fits, it anchors to the *top*: the
    /// rounding remainder of the view height over whole cells then sits at
    /// the bottom edge, not as a visible band under the titlebar. When the
    /// grid is momentarily taller than the drawable — mid-drag, before the
    /// debounced winsize lands (M2.9) — it anchors to the *bottom* instead,
    /// so the live edge (the prompt) stays put and the top clips; pinning
    /// the top in that case was the visible "text jumps" of a divider drag
    /// (M5.4).
    static func contentRect(
        in drawableSize: CGSize, scale: CGFloat, gridHeight: CGFloat, topInset: CGFloat
    ) -> CGRect {
        let bottom = drawableSize.height - TerminalLayout.insets.bottom * scale
        let fits = topInset * scale + gridHeight <= bottom
        return CGRect(
            x: TerminalLayout.insets.left * scale,
            y: fits ? topInset * scale : bottom - gridHeight,
            width: max(0, drawableSize.width - TerminalLayout.insetWidth * scale),
            height: gridHeight)
    }

    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }

    /// The dim wash over unfocused panes (M5.2). Called by
    /// `SplitViewController.noteFocus` for both the old and the new focused
    /// pane.
    func applyFocusAppearance() {
        focusDimView?.isHidden = isFocusedPane
        reportFocusIfNeeded()
    }
}

/// Covers a pane to dim it without intercepting input — clicks, scrolls
/// and hovers fall through to the terminal view beneath.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
