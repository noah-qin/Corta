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
    /// The font family in use, from the settings page (M6.1). The sentinel
    /// `Configuration.systemFontFamily` means System Monospaced. Kept so a
    /// config change can tell a family swap from a size change — they need
    /// the same rebuild, but a size change has its own path (`setFontSize`)
    /// that short-circuits when the size is unchanged.
    var fontFamily: String = Configuration.systemFontFamily
    /// Unspent trackpad magnification (M6.14). Storage lives here because
    /// the gesture handling is in `ViewController+Commands`, an extension.
    var pinchAccumulator: CGFloat = 0
    /// M6.3 — the long-task heuristic for this pane.
    let taskNotifier = TaskNotifier()
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
    /// The link range under the pointer (M7.9), underlined by the renderer
    /// so the target is visible before a click can open it. Storage lives
    /// here because `ViewController+Links` is an extension.
    var hoveredLink: TerminalSelection?
    /// The current text selection, owned by `ViewController+Selection.swift`
    /// (Track C) and read by the render loop. Stored here because extensions
    /// cannot add storage.
    var selection: TerminalSelection?
    /// The unfocused-pane dim (M5.2): a translucent wash over the pane, so
    /// which pane owns the keyboard is visible at a glance — the hidden
    /// cursor alone was too subtle. Above the terminal canvas, below the
    /// search bar's glass; it never intercepts input (`PassthroughView`).
    var focusDimView: NSView?
    /// The accent ring around the pane that owns the keyboard (M5.2, revised)
    /// — the positive half of the focus signal, so an unfocused pane no
    /// longer has to be dimmed to the point of looking disabled.
    var focusRingView: NSView?
    /// Shown instead of a terminal when this pane could not be built —
    /// no Metal device, no glyph atlas, or no child process (`PaneFailureView`).
    /// Non-nil is the one state in which `isOperable` is false.
    var failureView: PaneFailureView?
    /// A one-line report that the session started, but not the way it was
    /// asked to (a fallback shell or directory). Shown once the view is on
    /// screen, where the toast can actually be seen.
    private var pendingSessionNotice: String?
    /// Notification observers are process-lifetime and `setUpPane` can run
    /// twice (a retry after a failure); registering again would double every
    /// config change.
    private var didInstallObservers = false
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
    /// Backing store for `refreshProcessFactsIfStale`.
    private var cachedProcessName: String?
    private var cachedDirectory: String?
    private var lastProcessFactsRefresh: CFTimeInterval = 0
    /// True for a moment after a resize, while the title carries the grid
    /// size (see `composedWindowTitle`).
    private var isShowingTransientSize = false
    private var transientSizeReset: DispatchWorkItem?

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
        resizeDebouncer?.flush()
    }

    /// The grid a new window opens with, from the config file (M7.14). The
    /// window's content size is derived from this and the font's cell
    /// metrics, never from hardcoded points, so it follows a font or size
    /// change — and `columns × rows` keeps meaning cells rather than pixels.
    ///
    /// Read per pane rather than cached at launch: a change to the file
    /// applies to the next window opened, which is the only moment an initial
    /// size can apply at all.
    private var configuredGridSize: TerminalSize {
        let configuration = ConfigurationStore.shared.configuration
        return TerminalSize(
            rows: UInt16(configuration.rows), columns: UInt16(configuration.columns))
    }
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

    /// Whether this pane has a terminal at all. False means `setUpPane`
    /// failed and `failureView` is showing: there is nothing to render, no
    /// child to write to, and no cell metrics measured from a real atlas.
    /// Everything the window and the split tree call into has to survive
    /// that state rather than trap on an implicitly-unwrapped nil.
    var isOperable: Bool { terminalRenderer != nil && session != nil }

    /// The cell metrics geometry is measured from, or an estimate from the
    /// system face when the renderer could not be built. A broken pane still
    /// has to answer the split tree's minimum-size walk and the window's
    /// initial sizing; answering with an estimate keeps it from taking the
    /// whole window's layout down with it.
    private var cellMetrics: (cellWidth: CGFloat, cellHeight: CGFloat) {
        if let terminalRenderer {
            let metrics = terminalRenderer.pointMetrics
            return (metrics.cellWidth, metrics.cellHeight)
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        return (
            cellWidth: font.maximumAdvancement.width,
            cellHeight: (font.ascender - font.descender + font.leading).rounded(.up)
        )
    }

    let minimumColumns = 20
    let minimumRows = 5

    /// The smallest pixel area the pane tolerates, at the current cell
    /// metrics — the leaf value of the split tree's minimum-size walk
    /// (M5.4).
    var minimumContentSize: CGSize {
        let metrics = cellMetrics
        return CGSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + TerminalLayout.insetHeight)
    }

    /// The grid size that fits a pixel area, using the current cell metrics
    /// and this pane's insets — how a split predicts the new pane's winsize
    /// before layout settles it exactly.
    func gridSize(fitting size: CGSize) -> TerminalSize {
        let metrics = cellMetrics
        return TerminalSize(
            rows: UInt16(max(1, (size.height - verticalInsets) / metrics.cellHeight)),
            columns: UInt16(max(1, (size.width - TerminalLayout.insetWidth) / metrics.cellWidth)))
    }

    /// The window size that fits the initial grid exactly. With
    /// `.fullSizeContentView` the pane area spans the whole frame — and
    /// `setContentSize` sizes the frame on this OS — so this is the *frame*
    /// size: grid cells plus this pane's insets and the measured chrome.
    /// The first pane's pre-layout frame and the window's initial sizing
    /// both derive from it, so the session is born at its final size. Use
    /// the whole window chrome here, not `topInset`: before the root pane's
    /// constraints settle, its temporary position can make it look as if it
    /// does not touch the top of the window and omit the titlebar entirely.
    var initialWindowContentSize: NSSize {
        let metrics = cellMetrics
        let grid = initialGridSize ?? configuredGridSize
        return NSSize(
            width: CGFloat(grid.columns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(grid.rows) * metrics.cellHeight + TerminalLayout.insetHeight
                + windowChrome)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpPane()
    }

    /// Builds the pane: renderer, session, view hierarchy, wiring.
    ///
    /// Separate from `viewDidLoad` because it is also the retry path. Three
    /// things have to exist before a pane can draw — a Metal device, an atlas
    /// for the configured face, and a child on a PTY — and each can fail on a
    /// machine Corta is otherwise fine on: a `$SHELL` pointing at a shell that
    /// was uninstalled, a restored working directory on an unmounted volume.
    /// Until M7 each of those was a `fatalError` or a `try!`, so the answer to
    /// "your login shell moved" was a crash report. Now the recoverable ones
    /// degrade (`startSession`, `makeRenderer`) and the rest present
    /// `PaneFailureView`, whose Try Again runs this again.
    private func setUpPane() {
        // The settings page's font and size (M6.1). Read here rather than
        // pushed in later: a pane created at any time — a split, a new tab —
        // gets the current values by asking, and nothing has to remember to
        // tell it.
        let configuration = ConfigurationStore.shared.configuration
        fontSize = min(64, max(8, configuration.fontSize))
        fontFamily = configuration.fontFamily
        guard let device = self.device ?? MTLCreateSystemDefaultDevice() else {
            // Not retryable: a Mac that reports no Metal device will not grow
            // one while the app is running.
            presentFailure(
                title: L10n.text("failure.title.metal"),
                detail: L10n.text("failure.detail.metal"), canRetry: false)
            return
        }
        self.device = device
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        do {
            terminalRenderer = try makeRenderer(device: device, scale: scale)
        } catch {
            presentFailure(
                title: L10n.text("failure.title.renderer"),
                detail: Self.describe(error), canRetry: true)
            return
        }
        commandQueue = device.makeCommandQueue()

        // The session comes before the view hierarchy: with no child there is
        // no terminal to lay out, and the failure view should take the pane
        // rather than sit behind a live canvas with nothing driving it.
        let initialSize = initialGridSize ?? configuredGridSize
        let started: StartedSession
        do {
            started = try Self.startSession(
                size: initialSize, directory: inheritedWorkingDirectory,
                scrollbackLimit: configuration.scrollbackLines)
        } catch {
            presentFailure(
                title: L10n.text("failure.title.session"),
                detail: Self.describe(error), canRetry: true)
            return
        }
        session = started.session
        pendingSessionNotice = started.notice
        lastRequestedSize = initialSize

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
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.unfocusedDim).cgColor
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

        // The focus *indicator*, as opposed to the dim.
        //
        // A 22%-black wash over every pane but one was the whole signal, and
        // it said the wrong thing: a heavily dimmed pane reads as disabled or
        // suspended, not as "running, just not typing here" — and it took a
        // fifth of the contrast off text the user was still reading, in a
        // split whose entire purpose is watching two things at once. The
        // signal is now positive and on the active pane: an accent-coloured
        // ring around the pane that has the keyboard, with the dim reduced to
        // a hint. A ring is also the convention every other split UI on this
        // platform uses, so it needs no learning.
        let ring = PassthroughView()
        ring.wantsLayer = true
        ring.layer?.borderWidth = Self.focusRingWidth
        ring.layer?.cornerRadius = TerminalLayout.windowCornerRadius
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ring.isHidden = true
        ring.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(ring)
        // Inset by the border's own width: drawn flush to the pane's edge,
        // half of a 2pt border falls outside the view and the ring reads as
        // 1pt on the window's outer edges and 2pt against a divider.
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(
                equalTo: self.view.leadingAnchor, constant: Self.focusRingWidth / 2),
            ring.trailingAnchor.constraint(
                equalTo: self.view.trailingAnchor, constant: -Self.focusRingWidth / 2),
            ring.topAnchor.constraint(
                equalTo: self.view.topAnchor, constant: Self.focusRingWidth / 2),
            ring.bottomAnchor.constraint(
                equalTo: self.view.bottomAnchor, constant: -Self.focusRingWidth / 2),
        ])
        focusRingView = ring

        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session?.resize(to: size)
        }
        if !didInstallObservers {
            didInstallObservers = true
            observeWindowFocus()
            observeConfiguration()
        }
        // Fires on the reader thread after every parse batch.
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
            guard let self else { return }
            // A Return is the one moment a terminal without shell
            // integration knows the user asked for something (M6.3).
            if bytes.contains(0x0D) { taskNotifier.noteCommandSubmitted(in: view.window) }
            session.write(bytes)
        }
        view.onScroll = { [weak self] gesture in
            self?.scroll(gesture)
        }
        view.onLiveResizeEnded = { [weak self] in
            self?.endLiveResize()
        }
        view.isNewLineMode = { [weak self] in
            self?.session?.isNewLineModeEnabled ?? false
        }
        view.keyboardEnhancements = { [weak self] in
            self?.session?.keyboardEnhancements ?? []
        }
        installNativeIntegrations(on: view)
        view.onMagnify = { [weak self] magnification in
            self?.magnify(by: magnification)
        }
        view.onMagnifyEnded = { [weak self] in
            self?.endMagnification()
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
            return TerminalFont.primary(ofSize: fontSize, family: fontFamily) as NSFont
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
        // Accessibility (`TerminalView+Accessibility.swift`). The view draws
        // with Metal and so has no text for AppKit to derive an accessibility
        // tree from; these two closures are that text.
        view.accessibilitySnapshotProvider = { [weak self] in
            guard let self, let session else { return nil }
            let grid = session.snapshot()
            return TerminalAccessibilitySnapshot(
                grid: grid,
                selection: selection.map { selectionRange(for: $0, in: grid) })
        }
        view.accessibilityCellFrameProvider = { [weak self] row, column in
            guard let self, let terminalRenderer else { return .zero }
            let metrics = terminalRenderer.pointMetrics
            return CGRect(
                x: TerminalLayout.insets.left + CGFloat(column) * metrics.cellWidth,
                y: topInset + CGFloat(row) * metrics.cellHeight,
                width: metrics.cellWidth, height: metrics.cellHeight)
        }
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
        guard let session, terminalRenderer != nil else { return false }
        if session.takeBell() {
            handleBell()
        }
        let hasOutput = outputPending.withLock { pending -> Bool in
            let was = pending
            pending = false
            return was
        }
        guard needsRedraw || hasOutput else { return false }
        // The title's ingredients — the OSC 0/2 title (M2.8), the OSC 7
        // working directory and the foreground process — all arrive as
        // output, so applying it here keeps the window and, with native
        // tabbing (M4.7), the tab label current without a timer. The
        // window's title is the focused pane's (M5.2); an unfocused pane's
        // title applies when it takes focus
        // (`SplitViewController.noteFocus`).
        if hasOutput, isFocusedPane {
            applyWindowTitle()
        }
        // While the search bar is open, output shifts what matches: re-run
        // the query against the new snapshot before this frame diffs it
        // (M4.4). Recomputed, not patched — `updateSearchResults` explains.
        if hasOutput, searchBar != nil {
            updateSearchResults(scrollsToMatch: false)
        }
        if hasOutput {
            // A screen reader following a build log has to hear the new lines,
            // not the ones from when it last asked. Rate-limited and gated on
            // VoiceOver actually running, inside the call.
            terminalView?.noteAccessibilityValueChanged()
            // Two things the child asked for, drained on the same batch
            // boundary every other "the child told us something" hand-off
            // uses: a clipboard write (OSC 52, M7.11) and the command
            // boundaries a shell with integration reports (OSC 133, M7.2).
            drainClipboardRequests()
            let finished = session.takeFinishedCommand()
            if session.hasShellIntegration {
                taskNotifier.noteCommandRunning(
                    session.isCommandRunning, exitStatus: finished, in: view.window)
            }
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
            currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink)
        return forced || damaged
    }

    /// M4.8, app side — dispatches on the configured bell mode. The core
    /// decided nothing beyond "a bell happened" (`Terminal.takeBell()`).
    private func handleBell() {
        switch ConfigurationStore.shared.configuration.bell {
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
        // A parse batch has landed on the grid. Emitted from the reader
        // thread, so it is a point rather than an interval — the interval it
        // would close began in `keyDown` on another thread
        // (`InputLatencySignposts`).
        InputLatencySignposts.emit(.output)
        outputPending.withLock { $0 = true }
        // The MainActor hop, measured separately: this is the stage a busy
        // main thread lengthens, and the one an end-to-end number cannot
        // tell apart from a slow parse.
        let wake = InputLatencySignposts.begin(.wake)
        Task { @MainActor [weak self] in
            InputLatencySignposts.end(.wake, wake)
            self?.terminalView?.setNeedsRedraw()
            self?.taskNotifier.noteOutput()
        }
    }

    /// Marks the display dirty and wakes the display link — for local changes
    /// (layout, scrolling) that produce no PTY output.
    func invalidateDisplay() {
        needsRedraw = true
        terminalView?.setNeedsRedraw()
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
        // The title carries the grid size, so it changes with the drag —
        // which is what makes the live size visible while resizing, the way
        // Terminal.app shows it.
        if isFocusedPane {
            invalidateProcessFacts()
            noteTransientSizeChange()
            applyWindowTitle()
        }
    }

    // MARK: - Window title

    /// What the title bar says for this pane: what is running, where, and
    /// how big the grid is — the same three facts Terminal.app shows, for
    /// the same reason. "Corta" alone answered none of the questions asked
    /// of a title bar with four windows open.
    ///
    /// `<title or directory> — <process> — <columns>×<rows>`, with any part
    /// that is unknown left out rather than filled with a placeholder. The
    /// first part prefers the OSC 0/2 title, because a program that sets one
    /// (an editor, `claude`, a long build) is saying something more useful
    /// than its own name; a shell that sets none falls back to the working
    /// directory, abbreviated with `~`.
    ///
    /// Every ingredient except the size comes from the child, which is
    /// hostile input (`SECURITY.md` §2). Each is capped and stripped of
    /// control characters: a title is drawn by AppKit, not by the terminal,
    /// and an unbounded one is an unbounded allocation per output batch.
    var composedWindowTitle: String {
        guard session != nil else { return "Corta" }
        refreshProcessFactsIfStale()
        var parts: [String] = []
        if let title = Self.sanitizedTitleComponent(session.windowTitle) {
            parts.append(title)
        } else if let directory = cachedDirectory {
            parts.append(Self.abbreviated(directory))
        }
        if let process = Self.sanitizedTitleComponent(cachedProcessName) {
            parts.append(process)
        }
        // The grid size, only while it is changing.
        //
        // It used to be appended permanently, so the title read
        // "~/Corta — zsh — 120×27" for the whole life of the window: a third
        // of the space, and with tabs a third of every tab label, spent on a
        // number that is interesting for the two seconds of a drag and never
        // again. Terminal.app shows it during a resize for exactly that
        // reason. With tabs the cost is worse than cosmetic — the tab label
        // truncates from the right, so the directory or task name the user is
        // actually distinguishing tabs by was the first thing to disappear.
        if let size = lastRequestedSize, isShowingTransientSize {
            parts.append("\(size.columns)×\(size.rows)")
        }
        return parts.isEmpty ? "Corta" : parts.joined(separator: " — ")
    }

    /// Applies this pane's title to the window, plus the proxy icon for its
    /// working directory — the folder in the title bar, which makes the path
    /// draggable and ⌘-clickable the way every document window's is.
    ///
    /// The represented URL is only set for a directory that exists: the path
    /// arrives over OSC 7 from the child, and a proxy icon is something the
    /// user can drag into another application.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        let title = composedWindowTitle
        if window.title != title { window.title = title }

        var isDirectory: ObjCBool = false
        if let path = cachedDirectory,
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            let url = URL(fileURLWithPath: path)
            if window.representedURL != url { window.representedURL = url }
        } else if window.representedURL != nil {
            window.representedURL = nil
        }
    }

    /// Shows the grid size in the title for a moment after a resize, then
    /// takes it away again. Called from `resizeSessionToFitView`, which is
    /// the only place the size changes.
    func noteTransientSizeChange() {
        isShowingTransientSize = true
        transientSizeReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            isShowingTransientSize = false
            transientSizeReset = nil
            applyWindowTitle()
        }
        transientSizeReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transientSizeDuration, execute: work)
    }

    private static let transientSizeDuration: TimeInterval = 1.5

    /// The process name and directory behind the title, and when they were
    /// last read.
    ///
    /// Both are syscalls — `tcgetpgrp`, `proc_name`, `proc_pidinfo` — and the
    /// title is rebuilt on every output batch, which during a `yes` or a
    /// build is thousands of batches a second. Refreshed on an interval
    /// instead: a directory that changed a quarter of a second ago is not
    /// worth three syscalls per frame, and the OSC 0/2 title (the part a
    /// program updates deliberately) is read fresh every time regardless.
    private func refreshProcessFactsIfStale() {
        let now = CACurrentMediaTime()
        guard now - lastProcessFactsRefresh >= Self.processFactsInterval else { return }
        lastProcessFactsRefresh = now
        cachedProcessName = session.activeProcessName
        cachedDirectory = session.currentDirectory
    }

    /// Forces the next title to re-read them — for the moments where waiting
    /// out the interval would show something stale to the user: taking focus,
    /// and a command boundary the shell reported.
    func invalidateProcessFacts() {
        lastProcessFactsRefresh = 0
    }

    private static let processFactsInterval: CFTimeInterval = 0.4

    /// Trims a child-supplied component to something a title bar can hold:
    /// control characters out (a newline in a title truncates it visually and
    /// a private-use scalar can be unrenderable), and a hard length cap.
    private static func sanitizedTitleComponent(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned =
            text
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count > titleComponentLimit else { return cleaned }
        return cleaned.prefix(titleComponentLimit) + "…"
    }

    private static let titleComponentLimit = 80

    /// `/Users/noah/Developer` → `~/Developer`, and a bare directory name for
    /// anything deeper — the whole path in a title bar is noise, and the
    /// proxy icon carries it for anyone who wants it.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Runs at vsync, on the main thread — reads the latest grid without
    /// ever blocking the reader thread (`PERFORMANCE.md` §2.1).
    private func render(
        into renderPassDescriptor: MTLRenderPassDescriptor, drawableSize: CGSize, drawable: CAMetalDrawable
    ) {
        guard let session, let terminalRenderer, let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
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
            currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        // `commit` covers encode-and-submit; `gpu` runs from submission to
        // the completion handler, which is the only place the GPU's own time
        // — and any wait for a drawable to be recycled — becomes visible.
        let gpu = InputLatencySignposts.begin(.gpu)
        if gpu != nil {
            commandBuffer.addCompletedHandler { _ in
                InputLatencySignposts.end(.gpu, gpu)
            }
        }
        let commit = InputLatencySignposts.begin(.commit)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        InputLatencySignposts.end(.commit, commit)
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

    // MARK: - Failure paths

    /// The atlas for the configured face, falling back to the system face at
    /// the default size.
    ///
    /// `MonospacedFontCatalog` verifies a family before Corta offers it, but a
    /// family named in the config file only has to pass that check — the atlas
    /// can still fail to build for a face it vouched for, or for a size at
    /// which the metrics degenerate. The system monospaced face at the default
    /// size is the one combination Corta stands behind (`CLAUDE.md`), so it is
    /// the fallback rather than a failure.
    private func makeRenderer(device: MTLDevice, scale: CGFloat) throws -> TerminalRenderer {
        do {
            return try TerminalRenderer(
                device: device,
                font: TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
        } catch {
            fontSize = Self.defaultFontSize
            fontFamily = Configuration.systemFontFamily
            return try TerminalRenderer(
                device: device,
                font: TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
        }
    }

    struct StartedSession {
        let session: TerminalSession
        /// Set when a fallback was used, so the pane can say it is running
        /// something other than what was asked for instead of leaving the
        /// user to wonder why their prompt looks wrong.
        let notice: String?
    }

    /// Starts the child, degrading rather than failing whenever only *part* of
    /// the request is impossible.
    ///
    /// Two ingredients come from outside Corta and can both be stale: `$SHELL`
    /// (a shell that was uninstalled, a Homebrew prefix that moved) and the
    /// working directory (a restored session's directory on a volume that is
    /// no longer mounted, or one that has been deleted). Either alone used to
    /// abort the entire pane. The chain drops the failing ingredient first and
    /// only then the other, so a bad directory still gets you your shell and a
    /// bad shell still gets you your directory. `/bin/sh` in `/` is the last
    /// rung because POSIX guarantees both exist.
    private static func startSession(
        size: TerminalSize, directory: String?, scrollbackLimit: Int
    ) throws(PTYError) -> StartedSession {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = NSHomeDirectory()
        // Launched from Finder the app inherits "/" as its working directory,
        // so the shell opened in the filesystem root. A terminal should start
        // where a login shell would — and a split pane starts where the pane
        // it was split from is (M5.5).
        let preferred = directory ?? home
        let attempts: [(shell: String, directory: String, notice: String?)] = [
            (configured, preferred, nil),
            (configured, home, L10n.text("failure.notice.fallbackDirectory")),
            ("/bin/zsh", preferred, L10n.format("failure.notice.fallbackShell", "/bin/zsh")),
            ("/bin/zsh", home, L10n.format("failure.notice.fallbackShell", "/bin/zsh")),
            ("/bin/sh", "/", L10n.format("failure.notice.fallbackShell", "/bin/sh")),
        ]
        var attempted = Set<String>()
        var lastError = PTYError.spawnFailed(code: ENOENT)
        for attempt in attempts {
            // With no `$SHELL` and no inherited directory several rungs are
            // the same command; re-running a spawn that just failed only
            // delays the failure view.
            guard attempted.insert("\(attempt.shell)\u{0}\(attempt.directory)").inserted
            else { continue }
            do {
                let session = try TerminalSession(
                    executable: attempt.shell, arguments: ["-l"], size: size,
                    workingDirectory: attempt.directory,
                    // Per session: a running child's history cannot be
                    // re-limited without discarding lines, so a change
                    // applies to sessions opened after it.
                    scrollbackLimit: scrollbackLimit)
                return StartedSession(session: session, notice: attempt.notice)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// One line a person can act on. `PTYError` writes its description for
    /// exactly this purpose; anything else falls back to Foundation's.
    ///
    /// Cast to the concrete `PTYError` type, not the `CustomStringConvertible`
    /// protocol: recent Swift gives every `Error` a synthesized
    /// `CustomStringConvertible` conformance, so `error as? CustomStringConvertible`
    /// always succeeds and the `localizedDescription` fallback below it never
    /// runs — a non-`PTYError` (an `NSError` from a system API, say) would
    /// print its raw synthesized description instead of the friendly
    /// Foundation-provided one.
    private static func describe(_ error: Error) -> String {
        (error as? PTYError)?.description ?? error.localizedDescription
    }

    /// Replaces the pane's content with an explanation and the two actions
    /// that can help. The terminal view is never built in this state, so
    /// `isOperable` is false and every geometry and render entry point
    /// short-circuits.
    private func presentFailure(title: String, detail: String, canRetry: Bool) {
        failureView?.removeFromSuperview()
        let failure = PaneFailureView(title: title, detail: detail, canRetry: canRetry)
        failure.onRetry = { [weak self] in self?.retryAfterFailure() }
        failure.onOpenSettings = { SettingsWindowController.shared.show(nil) }
        failure.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failure)
        NSLayoutConstraint.activate([
            failure.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failure.topAnchor.constraint(equalTo: view.topAnchor),
            failure.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        failureView = failure
    }

    private func retryAfterFailure() {
        failureView?.removeFromSuperview()
        failureView = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        focusDimView?.removeFromSuperview()
        focusDimView = nil
        setUpPane()
        guard isOperable, let terminalView else { return }
        // The window settled long before this retry, so the startup gate that
        // holds back transient layouts has nothing left to protect against —
        // and the pane needs a winsize measured at real cell metrics, which it
        // did not have while the failure view was up.
        didSizeWindow = true
        view.window?.makeFirstResponder(terminalView)
        resizeSessionToFitView()
        invalidateDisplay()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Reported here rather than at construction: a toast needs a view on
        // screen to appear over.
        if let notice = pendingSessionNotice {
            pendingSessionNotice = nil
            terminalView?.showToast(notice, kind: .warning)
        }
    }

    /// The dim wash over unfocused panes (M5.2). Called by
    /// `SplitViewController.noteFocus` for both the old and the new focused
    /// pane.
    func applyFocusAppearance() {
        // A single pane needs neither: there is nothing to distinguish it
        // from, and a ring around the only pane is decoration.
        let inSplit = splitController?.hasMultiplePanes == true
        focusDimView?.isHidden = isFocusedPane || !inSplit
        focusRingView?.isHidden = !isFocusedPane || !inSplit
        // The accent colour is the user's and can change while the app runs;
        // Increase Contrast also needs a heavier ring than a tinted hairline.
        focusRingView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
        focusRingView?.layer?.borderWidth =
            SystemAccessibility.increaseContrast ? Self.focusRingWidth + 1 : Self.focusRingWidth
        reportFocusIfNeeded()
    }

    /// 8% rather than 22%: enough to tell two panes apart at a glance
    /// alongside the ring, little enough that the unfocused pane's text is
    /// still text you can read.
    static let unfocusedDim: CGFloat = 0.08
    static let focusRingWidth: CGFloat = 2
}

/// Covers a pane to dim it without intercepting input — clicks, scrolls
/// and hovers fall through to the terminal view beneath.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
