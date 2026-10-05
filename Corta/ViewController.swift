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
import CoreText
import CortaTerminal
import Metal
import QuartzCore

/// One pane: a `TerminalSession` and the renderer and view that draw it.
/// Knows no sibling panes beyond `splitController` (D07). This file owns
/// lifecycle and the session; the render loop is `PaneFrameLoop`'s, the
/// window title `PaneWindowTitle`'s, search `PaneSearch`'s, the remote side
/// `PaneRemote`'s and the menu commands `PaneCommands`', and the remaining
/// behaviour lives in the `ViewController+<concern>.swift` extensions.
class ViewController: NSViewController, PaneSearchHost, PaneRemoteHost, PaneCommandsHost {
    // Not `private`: extensions reach these and cannot add storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    /// Decides when a frame is owed and draws it; the pane supplies the
    /// content and the output-batch stage.
    private(set) lazy var frameLoop = makeFrameLoop()
    /// The window title and proxy icon this pane shows while focused.
    private(set) lazy var windowTitle = makeWindowTitle()
    /// Kept so a font change can rebuild the renderer.
    var device: MTLDevice!
    /// A change rebuilds the renderer: the atlas is rasterised for one size.
    var fontSize: CGFloat = ViewController.defaultFontSize
    /// A temporary zoom, which `configurationChanged` leaves alone until
    /// `resetFontSize`.
    var isFontSizeZoomed = false
    /// `Configuration.systemFontFamily` means System Monospaced. Kept to tell a
    /// family swap from a size change.
    var fontFamily: String = Configuration.systemFontFamily
    let taskNotifier = TaskNotifier()
    /// Terminal.app's stock profile, so TUIs keep the same proportions in both.
    static let defaultFontSize: CGFloat = 12
    /// Set before the view loads for a split, so the shell's first output is
    /// laid out at the right width, not reflowed.
    var inheritedWorkingDirectory: String?
    var initialGridSize: TerminalSize?

    /// Applied once at spawn; set before the view loads.
    var preset: Preset?
    /// What actually spawned — after a fallback, not what was asked for. The
    /// remote-state composition and Reconnect read it.
    private(set) var launchedCommand: (executable: String, arguments: [String])?
    /// Cleared when the viewport moves (`scrollOffset`'s `didSet`), so
    /// `effectiveCommand` never targets a command scrolled out of view.
    /// `jumpToCommand` sets it after its own scroll.
    var selectedCommandID: Int?

    var scrollOffset = 0 {
        didSet {
            guard scrollOffset != oldValue else { return }
            selectedCommandID = nil
            if scrollOffset == 0 {
                sawOutputWhileScrolled = false
                scrollAnchorTotalPushed = nil
            } else {
                // Including `prepareFrame`'s own shift, so the next batch's growth is
                // measured from there.
                scrollAnchorTotalPushed = session?.scrollbackTotalPushed
            }
            updateScrollPositionIndicator()
            search.placeClearOfContent()
        }
    }

    /// The total the offset was set against; `nil` at the bottom.
    /// `prepareFrame` keeps the viewport on the same document row with it.
    var scrollAnchorTotalPushed: Int?

    var scrollPositionIndicator: ScrollPositionIndicator?

    /// The fact a person scrolled up to wait for.
    var sawOutputWhileScrolled = false
    /// Cursor changes on transitions only: resetting the arrow every move
    /// fights the divider's resize cursor.
    var hoveringLink = false
    /// Underlined, so the target shows before a click opens it.
    var hoveredLink: TerminalSelection?
    var selection: TerminalSelection?
    /// Dims unfocused panes; never intercepts input (`PassthroughView`).
    var focusDimView: NSView?
    /// On `hasUserFocus`, not `isFocusedPane`: hidden when the window resigns
    /// key, like the ring — neither claims where the keyboard *would* go.
    var focusHighlightView: NSView?
    /// The positive focus signal, so unfocused panes need not look disabled.
    var focusRingView: NSView?
    /// Re-tensioned every layout, so a top pane's ring clears a tab bar that
    /// appears, hides or is dragged out.
    private var focusRingTopConstraint: NSLayoutConstraint?
    /// Non-nil exactly when `isOperable` is false.
    var failureView: PaneFailureView?
    /// A fallback shell or directory, reported once the toast can be seen.
    private var pendingSessionNotice: String?
    /// `setUpPane` can run twice (a retry); observers must not.
    private var didInstallObservers = false
    /// `nil` until the first `?1004` report, so it always goes out.
    var lastReportedFocus: Bool?
    /// Keeps transient startup layouts from reaching the child
    /// (`resizeSessionToFitView`).
    var didSizeWindow = false
    private var resizeDebouncer: ResizeDebouncer!

    /// ⌘+/⌘− re-fit the window to keep this grid size.
    var lastRequestedSize: TerminalSize?
    /// The usable area a run of font changes started from, and the frame and
    /// usable area the last one left; either changed since starts a new run
    /// (`fitWindowToWholeCells`).
    var fontChangeAnchor: (usable: CGSize, frameSize: CGSize, fittedUsable: CGSize)?

    /// Scrollback search: the bar, its sweeps and the highlighted matches.
    private(set) lazy var search = PaneSearch(host: self)
    /// Whether this pane talks to another machine, Reconnect, remote
    /// references and the SFTP browser's entry.
    private(set) lazy var remote = PaneRemote(host: self)
    /// Font size, copy and export, drops and Services, Finder actions and
    /// app-initiated `cd`.
    private(set) lazy var commands = PaneCommands(host: self)
    let inputSourceIndicator = PaneInputSourceIndicator()

    /// The child sees the final size now, not after the debounce.
    func endLiveResize() {
        resizeDebouncer?.flush()
    }

    /// Read per pane, not at launch: a config change applies to the next
    /// window, the only moment an initial size can apply.
    private var configuredGridSize: TerminalSize {
        let configuration = ConfigurationStore.shared.configuration
        return TerminalSize(
            rows: UInt16(configuration.rows), columns: UInt16(configuration.columns))
    }
    /// Frame minus content layout rect — the only measure that follows a tab
    /// bar appearing. Before the window exists, the titlebar alone.
    var windowChrome: CGFloat {
        guard let window = view.window else { return TerminalLayout.titlebarHeight }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }
    /// Only a pane touching the window's top sits under the chrome.
    var topInset: CGFloat {
        guard view.window != nil else {
            return TerminalLayout.titlebarHeight + TerminalLayout.insets.top
        }
        return TerminalLayout.insets.top + chromeOverlap
    }
    /// The chrome share alone — what the focus ring, drawn flush, needs.
    private var chromeOverlap: CGFloat {
        guard let window = view.window else { return 0 }
        let distanceFromTop = window.frame.height - view.convert(view.bounds, to: nil).maxY
        return TerminalLayout.chromeOverlap(
            windowChrome: windowChrome, paneDistanceFromTop: distanceFromTop)
    }
    var verticalInsets: CGFloat { topInset + TerminalLayout.insets.bottom }

    var splitController: SplitViewController? { parent as? SplitViewController }
    /// Only the focused pane draws a cursor — part of the focus indicator.
    var isFocusedPane: Bool { splitController?.focusedPane === self }

    /// False when `setUpPane` failed: everything the window and split tree call
    /// must survive that rather than trap on an implicitly unwrapped nil.
    var isOperable: Bool { terminalRenderer != nil && session != nil }

    /// An estimate when the renderer failed, so a broken pane cannot take the
    /// window's layout down.
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

    /// Device pixels for `TIOCSWINSZ`: image clients size cells from them, and
    /// `kitten icat` refuses to run without.
    private func pixelSize(columns: Int, rows: Int, metrics: CellMetrics) -> (
        width: UInt16, height: UInt16
    ) {
        let width = CGFloat(columns) * metrics.cellWidth
        let height = CGFloat(rows) * metrics.cellHeight
        return (
            UInt16(min(CGFloat(UInt16.max), max(0, width))),
            UInt16(min(CGFloat(UInt16.max), max(0, height)))
        )
    }

    let minimumColumns = 20
    let minimumRows = 5

    var minimumContentSize: CGSize {
        let metrics = cellMetrics
        return CGSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + TerminalLayout.insetHeight)
    }

    /// How a split predicts the new pane's winsize before layout settles it.
    func gridSize(fitting size: CGSize) -> TerminalSize {
        let metrics = cellMetrics
        return TerminalSize(
            rows: Self.cellCount((size.height - verticalInsets) / metrics.cellHeight),
            columns: Self.cellCount((size.width - TerminalLayout.insetWidth) / metrics.cellWidth))
    }

    /// Clamped before converting: a zero metric makes the quotient infinite,
    /// and `UInt16(.infinity)` traps. A hair of slack, so a pane fitted to
    /// whole cells is not a cell short through rounding.
    nonisolated static func cellCount(_ quotient: CGFloat) -> UInt16 {
        guard quotient.isFinite else { return 1 }
        return UInt16(min(max(1, quotient + 0.001), CGFloat(UInt16.max)))
    }

    /// The *frame* size (`setContentSize` sizes the frame here) for the initial
    /// grid, so the session is born at its final size. Whole chrome, not
    /// `topInset`: before constraints settle, the root pane can look as if it
    /// does not touch the top.
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

    /// Builds a pane or retries a failed setup. Reconnect must reuse the exact
    /// recorded command; ordinary startup may fall back to a working shell.
    private func setUpPane(strictRespawn: Bool = false) {
        let configuration = ConfigurationStore.shared.configuration
        fontSize = min(64, max(8, configuration.fontSize))
        fontFamily = configuration.fontFamily
        guard let device = self.device ?? MTLCreateSystemDefaultDevice() else {
            presentFailure(
                title: L10n.text("failure.title.metal"),
                detail: L10n.text("failure.detail.metal"), canRetry: false)
            return
        }
        // Metal 4 is the only renderer (D21). A GPU without it — a virtual
        // machine's — gets this pane and no session, not a fallback.
        guard Metal4Backend.isSupported(by: device) else {
            presentFailure(
                title: L10n.text("failure.title.metal4"),
                detail: L10n.text("failure.detail.metal4"), canRetry: false)
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

        var initialSize = initialGridSize ?? configuredGridSize
        if let terminalRenderer {
            let pixels = pixelSize(
                columns: Int(initialSize.columns), rows: Int(initialSize.rows),
                metrics: terminalRenderer.metrics)
            initialSize = TerminalSize(
                rows: initialSize.rows, columns: initialSize.columns,
                pixelWidth: pixels.width, pixelHeight: pixels.height)
        }
        let started: StartedSession
        do {
            if strictRespawn, let command = remote.reconnectCommand {
                started = StartedSession(
                    session: try respawn(command, size: initialSize, configuration: configuration),
                    notice: nil, executable: command.executable, arguments: command.arguments)
            } else {
                started = try Self.startSession(
                    size: initialSize, directory: inheritedWorkingDirectory,
                    scrollbackLimit: configuration.scrollbackLines,
                    commandHistoryLimit: configuration.commandHistoryLimit, preset: preset,
                    directoryCompletion: configuration.directoryCompletion)
            }
        } catch {
            presentFailure(
                title: L10n.text("failure.title.session"),
                detail: Self.describe(error), canRetry: true,
                canReconnect: remote.reconnectCommand.map {
                    PaneRemoteState.isRemoteLauncher(executable: $0.executable)
                } ?? false)
            return
        }
        session = started.session
        launchedCommand = (started.executable, started.arguments)
        windowTitle.reset(session: started.session)
        remote.reset()
        session.dynamicColors =
            AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
            .dynamicColors
        session.indexedPalette =
            AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
            .indexedPaletteDefaults
        pendingSessionNotice = started.notice
        lastRequestedSize = initialSize

        installPaneViews()
        installSessionCallbacks()
        installTerminalCallbacks(on: terminalView)
        // The PTY reader must not run until all callbacks and views are ready.
        session.start()
    }

    private func installPaneViews() {
        let contentSize = initialWindowContentSize
        self.view.setFrameSize(contentSize)

        let view = TerminalView(frame: NSRect(origin: .zero, size: contentSize))
        self.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        terminalView = view

        let dim = PassthroughView()
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

        let highlight = PassthroughView()
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(Self.focusHighlightAlpha).cgColor
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            highlight.topAnchor.constraint(equalTo: self.view.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        focusHighlightView = highlight

        let ring = PassthroughView()
        ring.wantsLayer = true
        ring.layer?.borderWidth = Self.focusRingWidth
        ring.layer?.cornerRadius = TerminalLayout.windowCornerRadius
        ring.layer?.borderColor = Self.focusRingColor.cgColor
        ring.isHidden = true
        ring.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(ring)
        let ringTop = ring.topAnchor.constraint(
            equalTo: self.view.topAnchor, constant: Self.focusRingWidth / 2)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(
                equalTo: self.view.leadingAnchor, constant: Self.focusRingWidth / 2),
            ring.trailingAnchor.constraint(
                equalTo: self.view.trailingAnchor, constant: -Self.focusRingWidth / 2),
            ringTop,
            ring.bottomAnchor.constraint(
                equalTo: self.view.bottomAnchor, constant: -Self.focusRingWidth / 2),
        ])
        focusRingTopConstraint = ringTop
        focusRingView = ring
    }

    private func installSessionCallbacks() {
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session?.resize(to: size)
        }
        if !didInstallObservers {
            didInstallObservers = true
            observeWindowFocus()
            observeConfiguration()
        }
        let generation = frameLoop.attach(session: session, renderer: terminalRenderer)
        let wake = frameLoop.outputWake
        taskNotifier.lastOutputUptimeNanoseconds = { wake.lastOutputUptimeNanoseconds }
        session.onChildExit = { [weak self] childExit in
            Task(priority: .userInitiated) { @MainActor in
                self?.noteChildExit(childExit, generation: generation)
            }
        }
    }

    private func installTerminalCallbacks(on view: TerminalView) {
        view.onRenderFrame = { [weak self] drawableSize, drawable in
            guard let self else {
                drawable.present()
                return true
            }
            return frameLoop.render(drawableSize: drawableSize, drawable: drawable)
        }
        view.shouldRenderFrame = { [weak self] in
            self?.frameLoop.prepareFrame() ?? false
        }
        // `view` weakly too: the closure is stored on it, and a strong capture
        // kept every closed pane's view — and its drawables — alive.
        view.addSubview(view.shellOverlay)
        view.addSubview(inputSourceIndicator.view)
        inputSourceIndicator.onChange = { [weak self] in self?.invalidateDisplay() }
        view.onInputContextChange = { [weak self, weak view] in
            guard let self, let view else { return }
            if view.window?.firstResponder !== view { inputSourceIndicator.view.isHidden = true }
            invalidateDisplay()
        }
        inputSourceIndicator.start()
        view.onCompletionKey = { [weak self] event in self?.handleDirectoryCompletionKey(event) ?? false }
        view.onKeyBytes = { [weak self, weak view] bytes in
            guard let self else { return }
            if bytes.contains(0x0D) { taskNotifier.noteCommandSubmitted(in: view?.window) }
            returnToBottomOnInput()
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
        view.applicationCursorKeys = { [weak self] in
            self?.session?.applicationCursorKeysEnabled ?? false
        }
        view.applicationKeypad = { [weak self] in
            self?.session?.applicationKeypadEnabled ?? false
        }
        view.optionAsMeta = {
            ConfigurationStore.shared.configuration.optionAsMeta
        }
        view.keybindings = {
            ConfigurationStore.shared.configuration.keybindings
        }
        commands.installNativeIntegrations(on: view)
        view.onMagnify = { [weak self] magnification in
            self?.commands.magnify(by: magnification)
        }
        view.onMagnifyEnded = { [weak self] in
            self?.commands.endMagnification()
        }
        view.onBackingScaleChange = { [weak self] scale in
            self?.rebuildAtlas(forBackingScale: scale)
        }
        view.onDrawableSizeChange = { [weak self] in
            self?.invalidateDisplay()
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
        view.onSearchKey = { [weak self] (event: NSEvent) -> Bool in
            self?.search.handleKey(event) ?? false
        }
        view.cellSize = CGSize(width: terminalRenderer.pointMetrics.cellWidth, height: terminalRenderer.pointMetrics.cellHeight)
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
        view.mouseTrackingMode = { [weak self] in
            self?.session?.sgrMouseTrackingMode ?? .off
        }
        view.mouseOverrideModifier = ConfigurationStore.shared.configuration.mouseOverrideModifier
        view.onMouseBytes = { [weak self] bytes in
            self?.session.write(bytes)
        }
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.inputSourceIndicator.refreshSource()
            self.splitController?.noteFocus(self)
        }
        view.cursorRectProvider = { [weak self] in
            guard let self, let terminalRenderer, session != nil else { return nil }
            let metrics = terminalRenderer.pointMetrics
            let cursor = session.snapshot().cursor
            return CGRect(
                x: TerminalLayout.insets.left + CGFloat(cursor.column) * metrics.cellWidth,
                y: topInset + CGFloat(cursor.row) * metrics.cellHeight,
                width: metrics.cellWidth, height: metrics.cellHeight)
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

    // MARK: - Teardown

    var cursorBlinkTimer: Timer?
    var cursorBlinkVisible = true
    var lastBlinkCursor: Cursor?
    var lastBlinkStyle: CursorStyle?

    /// Two close paths can reach one pane. Also checked by copy/export
    /// completions — the generation guard catches a newer build, not a
    /// teardown.
    var didTeardown = false

    /// The one place every close path (pane, tab, window, quit) funnels. Not
    /// `deinit`: the reader thread retains the session, so a closed window's
    /// shell would run on as an orphan.
    func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
        stopCursorBlink()
        inputSourceIndicator.stop()
        windowTitle.stop()
        search.close()
        commands.stop()
        taskNotifier.cancel()
        NotificationCenter.default.removeObserver(self)
        terminalView?.stopRendering()
        session?.stop()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Size or scale can change with no grid change the diff would see.
        invalidateDisplay()
        resizeSessionToFitView()
        updateFocusRingLayout()
        search.placeClearOfContent()
    }

    /// Tab bar changes are all layout passes, so `viewDidLayout` suffices.
    private func updateFocusRingLayout() {
        guard focusRingView != nil else { return }
        focusRingTopConstraint?.constant = chromeOverlap + Self.focusRingWidth / 2
        updateFocusRingCornerMask()
    }

    /// Only corners that are the window's, as `TerminalView` does for the
    /// drawable; this view is not flipped, so `MaxY` is the top.
    private func updateFocusRingCornerMask() {
        guard let window = view.window, let ring = focusRingView else { return }
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: view.convert(view.bounds, to: nil), windowSize: window.frame.size)
        var mask: CACornerMask = []
        if edges.top && edges.left { mask.insert(.layerMinXMaxYCorner) }
        if edges.top && edges.right { mask.insert(.layerMaxXMaxYCorner) }
        ring.layer?.maskedCorners = mask
    }

    private func makeFrameLoop() -> PaneFrameLoop {
        let loop = PaneFrameLoop()
        loop.onBell = { [weak self] in self?.handleBell() }
        loop.onOutputBatch = { [weak self] in self?.noteOutputBatch() }
        loop.content = { [weak self] hasOutput in self?.frameContent(hasOutput: hasOutput) }
        loop.onNeedsDisplay = { [weak self] in self?.terminalView?.setNeedsRedraw() }
        loop.topInset = { [weak self] in self?.topInset ?? 0 }
        return loop
    }

    private func makeWindowTitle() -> PaneWindowTitle {
        let title = PaneWindowTitle()
        title.resolveRemoteState = { [weak self] in self?.remote.resolveState() ?? .local }
        title.window = { [weak self] in self?.viewIfLoaded?.window }
        title.gridSize = { [weak self] in self?.lastRequestedSize }
        title.canApplyDeferred = { [weak self] in
            guard let self else { return false }
            return !didTeardown && isFocusedPane
        }
        return title
    }

    /// The output-batch stage: what a batch changes beyond the grid. Title,
    /// directory and process all arrive as output, so this keeps the window
    /// and tab title current without a timer; an unfocused pane's applies on
    /// focus.
    private func noteOutputBatch() {
        guard let session else { return }
        if isFocusedPane {
            windowTitle.apply()
        }
        if scrollOffset > 0, !sawOutputWhileScrolled {
            // Nothing else says so: no scroll bar, and the live screen is off view.
            sawOutputWhileScrolled = true
            updateScrollPositionIndicator()
        }
        // Search refresh is a full-scrollback sweep; off the render path.
        if search.bar != nil {
            search.scheduleBackgroundRefresh()
            // The cursor may have moved under the bar.
            search.placeClearOfContent()
        }
        // Rate-limited and gated on VoiceOver inside the call.
        terminalView?.noteAccessibilityValueChanged()
        drainClipboardRequests()
        let finished = session.takeFinishedCommand()
        // The prompt's return is the moment the program left: the title
        // names the shell again now, not an interval later.
        if finished != nil, isFocusedPane {
            windowTitle.invalidateProcessFacts()
            windowTitle.apply()
        }
        if session.hasShellIntegration {
            taskNotifier.noteCommandRunning(
                session.isCommandRunning, exitStatus: finished,
                commandID: finished != nil ? session.commandRecords.lastCompleted?.id : nil,
                in: view.window)
            // Ranked once a command ran there, not on every `cd`.
            if finished != nil, let directory = session.currentDirectory {
                DirectoryHistoryStore.shared.record(directory)
            }
        }
    }

    /// What this frame draws, and the overlays placed against it.
    private func frameContent(hasOutput: Bool) -> PaneFrameLoop.Content? {
        guard let session, let terminalRenderer else { return nil }
        let configuration = ConfigurationStore.shared.configuration
        let inputSnapshot = configuration.inputSourceIndicator == .off ? nil : session.inputLineSnapshot()
        let grid = inputSnapshot?.grid ?? session.snapshot()
        splitController?.placeInputSourceIndicator(from: self, configuration: configuration)
        updateShellOverlay(grid: grid)
        if let inputSnapshot {
            let metrics = terminalRenderer.pointMetrics
            inputSourceIndicator.update(grid: grid, hasIntegration: inputSnapshot.hasIntegration,
                promptRow: inputSnapshot.promptRow,
                focused: hasUserFocus && view.window?.firstResponder === terminalView,
                scrollOffset: scrollOffset, configuration: configuration,
                cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                topInset: topInset, compositionRect: terminalView.inputCompositionRect,
                blockedRects: terminalView.shellOverlay.occupiedRects + (search.bar.map { [$0.frame] } ?? []))
        } else { inputSourceIndicator.view.isHidden = true }
        if hasOutput, scrollOffset > 0, let anchor = scrollAnchorTotalPushed {
            // Keep the viewport on the same document row while scrolled away.
            // From this frame's own snapshot — a separate read could see more rows
            // and render a batch behind — and pinned to that total directly, since
            // the `didSet` would re-read the counter.
            if grid.scrollback.totalPushed > anchor {
                scrollOffset = ScrollbackCoordinates.reanchoredOffset(
                    scrollOffset, from: anchor, to: grid.scrollback.totalPushed)
                scrollAnchorTotalPushed = grid.scrollback.totalPushed
            }
        }
        let cursorStyle = effectiveCursorStyle(grid: grid)
        updateCursorBlink(grid: grid, style: cursorStyle, reset: hasOutput)
        return PaneFrameLoop.Content(
            grid: grid, scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0 && isFocusedPane && cursorBlinkVisible,
            selection: selection,
            searchMatches: search.matches.map { TerminalSelection($0, grid: grid) },
            currentSearchMatchIndex: search.currentMatchIndex, hoveredLink: hoveredLink,
            cursorStyle: cursorStyle)
    }

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

    /// A child that exited on its own. A user's close set `didTeardown` before
    /// stopping the session, and must not toast; a generation check alone
    /// would miss it.
    @MainActor
    private func noteChildExit(_: ChildExit, generation: Int) {
        guard !didTeardown, frameLoop.isCurrent(generation) else { return }
        // A dead child produces no output to rebuild the title; the `⟂ host`
        // badge would outlive its connection.
        windowTitle.invalidateProcessFacts()
        windowTitle.apply()
        // A remote launcher: the connection ended, and the way back is a new one.
        if let launchedCommand,
            PaneRemoteState.isRemoteLauncher(executable: launchedCommand.executable)
        {
            terminalView?.showToast(L10n.text("toast.connectionEnded"), kind: .warning)
        } else {
            terminalView?.showToast(L10n.text("toast.shellExited"), kind: .warning)
        }
    }

    /// For local changes that produce no output.
    func invalidateDisplay() {
        frameLoop.invalidate()
    }

    /// The grid now, or nil for a failed pane.
    func snapshot() -> Grid? {
        session?.snapshot()
    }

    func selectedText() -> String? {
        commands.selectedText()
    }

    // MARK: - Forwarding

    // Menu items, the palette and key bindings send their actions to the
    // first responder, and the pane is in its chain; the pane answers for
    // the collaborator that owns each one, and `validateMenuItem` asks it.

    @objc func performFindPanelAction(_ sender: Any?) { search.performFindPanelAction(sender) }
    @objc func reconnectRemote(_ sender: Any?) { remote.reconnectRemote(sender) }
    @objc func browseRemoteFiles(_ sender: Any?) { remote.browseRemoteFiles(sender) }
    @objc func copy(_ sender: Any?) { commands.copy(sender) }
    @objc func increaseFontSize(_ sender: Any?) { commands.increaseFontSize(sender) }
    @objc func decreaseFontSize(_ sender: Any?) { commands.decreaseFontSize(sender) }
    @objc func resetFontSize(_ sender: Any?) { commands.resetFontSize(sender) }
    @objc func exportText(_ sender: Any?) { commands.exportText(sender) }
    @objc func exportCommandOutput(_ sender: Any?) { commands.exportCommandOutput(sender) }
    @objc func revealWorkingDirectoryInFinder(_ sender: Any?) {
        commands.revealWorkingDirectoryInFinder(sender)
    }
    @objc func copyWorkingDirectoryPath(_ sender: Any?) { commands.copyWorkingDirectoryPath(sender) }
    @objc func changeDirectoryToParent(_ sender: Any?) { commands.changeDirectoryToParent(sender) }
    @objc func changeDirectoryToProjectRoot(_ sender: Any?) {
        commands.changeDirectoryToProjectRoot(sender)
    }
    @objc func openParentDirectoryInNewPane(_ sender: Any?) {
        commands.openParentDirectoryInNewPane(sender)
    }
    @objc func openProjectRootInNewPane(_ sender: Any?) { commands.openProjectRootInNewPane(sender) }

    /// `coalesce: false` delivers the size now: a font change is one step,
    /// and waiting out the drag debounce drew a frame of the new font over
    /// the old grid first.
    func resizeSessionToFitView(coalesce: Bool = true) {
        // Nothing reaches the child before `sizeSettled`: earlier layouts run at
        // transient sizes (the first after `setContentSize` is one titlebar short)
        // and would strand blank rows under the prompt. The session is born at the
        // target size, so nothing is lost. The check is the split controller's —
        // a pane in a split never fills the frame.
        guard didSizeWindow, session != nil, let terminalRenderer, view.window != nil,
            let splitController, splitController.sizeSettled
        else { return }
        let usable = CGSize(
            width: view.bounds.width - TerminalLayout.insetWidth,
            height: view.bounds.height - verticalInsets)
        let columns = Self.cellCount(usable.width / terminalRenderer.pointMetrics.cellWidth)
        let rows = Self.cellCount(usable.height / terminalRenderer.pointMetrics.cellHeight)
        let pixels = pixelSize(columns: Int(columns), rows: Int(rows), metrics: terminalRenderer.metrics)
        let size = TerminalSize(
            rows: rows, columns: columns, pixelWidth: pixels.width, pixelHeight: pixels.height)
        guard size != lastRequestedSize else {
            // A layout pass may have queued this size behind the debounce.
            if !coalesce { resizeDebouncer.flush() }
            return
        }
        // A column change reflows every row (DESIGN.md §3.1), so a stored
        // selection or offset would name the wrong text. A row-only change is
        // ordinary growth, already handled.
        if lastRequestedSize.map({ $0.columns != size.columns }) ?? false {
            selection = nil
            scrollOffset = 0
        }
        lastRequestedSize = size
        // Trailing edge only: drags and the zoom animation lay out per frame,
        // and rewrapping mid-gesture is the visible "text jumps".
        resizeDebouncer.resize(to: size, coalesce: coalesce)
        // The title shows the live size, as Terminal.app does.
        if isFocusedPane {
            windowTitle.invalidateProcessFacts()
            // Zoom changes the grid, but only a physical window drag needs
            // a temporary size label in the title and native tab.
            if view.inLiveResize { windowTitle.noteTransientSizeChange() }
            else { windowTitle.endTransientSize() }
            windowTitle.apply()
        }
    }

    // MARK: - Failure paths

    /// A configured face can pass the catalog and still fail to build; the
    /// system face at the default size is the fallback Corta stands behind
    /// (D11).
    private func makeRenderer(device: MTLDevice, scale: CGFloat) throws -> TerminalRenderer {
        let renderer: TerminalRenderer
        do {
            renderer = try TerminalRenderer(
                device: device,
                font: TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
        } catch {
            fontSize = Self.defaultFontSize
            fontFamily = Configuration.systemFontFamily
            renderer = try TerminalRenderer(
                device: device,
                font: TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
        }
        renderer.drawsCommandMarks = false
        // A finished decode schedules a frame; otherwise it waits for unrelated
        // output.
        renderer.kittyImageRenderer.onImagesReady = { [weak self] in
            DispatchQueue.main.async { self?.invalidateDisplay() }
        }
        return renderer
    }

    struct StartedSession {
        let session: TerminalSession
        /// A fallback was used, and the pane says so.
        let notice: String?
        /// The rung that succeeded, for `PaneRemoteState` and Reconnect.
        let executable: String
        let arguments: [String]
    }

    /// Degrades rather than fails: `$SHELL` and the directory can each be stale
    /// (uninstalled shell, unmounted volume), and neither alone may abort the
    /// pane. Each is dropped in turn; `/bin/sh` in `/` is guaranteed by POSIX.
    /// - Parameter configuredShell: a parameter so tests can stage a missing
    ///   shell without setting `$SHELL` for anything else.
    static func startSession(
        size: TerminalSize, directory: String?, scrollbackLimit: Int,
        commandHistoryLimit: Int = CommandRecordStore.defaultCapacity, preset: Preset? = nil,
        configuredShell: String? = nil, directoryCompletion: Bool = true
    ) throws(PTYError) -> StartedSession {
        // An uninstalled preset shell degrades to a working terminal.
        let configured =
            preset?.shell ?? configuredShell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments = preset.map { $0.arguments.isEmpty ? ["-l"] : $0.arguments } ?? ["-l"]
        // A preset adds and overrides, never removes (`SECURITY.md` §4.3).
        var environment = ChildEnvironment.default()
        for (key, value) in preset?.environment ?? [:] { environment[key] = value }
        let home = NSHomeDirectory()
        // From Finder the app's cwd is "/"; start where a login shell would.
        let preferred = preset?.directory ?? directory ?? home
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
            // Identical rungs only delay the failure view.
            guard attempted.insert("\(attempt.shell)\u{0}\(attempt.directory)").inserted
            else { continue }
            do {
                let session = try TerminalSession(
                    executable: attempt.shell,
                    // Only for the preset's own shell; a fallback may not understand them.
                    arguments: attempt.shell == configured ? arguments : ["-l"],
                    environment: directoryCompletion
                        ? ZshBootstrap.environment(environment, executable: attempt.shell,
                            arguments: attempt.shell == configured ? arguments : ["-l"])
                        : environment, size: size,
                    workingDirectory: attempt.directory,
                    // Applies to new sessions: shrinking a live one would drop lines.
                    scrollbackLimit: scrollbackLimit, commandHistoryLimit: commandHistoryLimit)
                return StartedSession(
                    session: session, notice: attempt.notice,
                    executable: attempt.shell,
                    arguments: attempt.shell == configured ? arguments : ["-l"])
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The recorded command, exactly — a fallback would silently turn a remote
    /// pane into a local shell.
    private func respawn(
        _ command: (executable: String, arguments: [String]),
        size: TerminalSize, configuration: Configuration
    ) throws(PTYError) -> TerminalSession {
        var environment = ChildEnvironment.default()
        for (key, value) in preset?.environment ?? [:] { environment[key] = value }
        // A local cwd for the launcher; the remote side lands where it lands.
        return try TerminalSession(
            executable: command.executable, arguments: command.arguments,
            environment: configuration.directoryCompletion
                ? ZshBootstrap.environment(environment, executable: command.executable, arguments: command.arguments)
                : environment, size: size,
            workingDirectory: preset?.directory ?? inheritedWorkingDirectory ?? NSHomeDirectory(),
            scrollbackLimit: configuration.scrollbackLines,
            commandHistoryLimit: configuration.commandHistoryLimit)
    }

    /// Casts to `PTYError`, not `CustomStringConvertible`: every `Error` now
    /// conforms to that, so the `localizedDescription` fallback would never run.
    private static func describe(_ error: Error) -> String {
        (error as? PTYError)?.description ?? error.localizedDescription
    }

    /// With `isOperable` false every geometry and render entry short-circuits.
    /// `canReconnect` adds Reconnect, described as a new connection.
    private func presentFailure(
        title: String, detail: String, canRetry: Bool, canReconnect: Bool = false
    ) {
        failureView?.removeFromSuperview()
        let failure = PaneFailureView(
            title: title, detail: detail, canRetry: canRetry, canReconnect: canReconnect)
        failure.onRetry = { [weak self] in self?.retryAfterFailure() }
        failure.onReconnect = { [weak self] in self?.remote.reconnectRemote(nil) }
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
        // Or nothing is focused and assistive technology hears nothing.
        view.window?.makeFirstResponder(failure.primaryAction)
        NSAccessibility.post(element: failure, notification: .layoutChanged)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: failure.announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    private func retryAfterFailure() {
        rebuildPane(strictRespawn: false)
    }

    /// Behind Try Again (the ladder) and Reconnect (the exact command).
    func rebuildPane(strictRespawn: Bool) {
        failureView?.removeFromSuperview()
        failureView = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        focusDimView?.removeFromSuperview()
        focusDimView = nil
        setUpPane(strictRespawn: strictRespawn)
        guard isOperable, let terminalView else { return }
        // The window settled long ago; this pane needs a real winsize now.
        didSizeWindow = true
        view.window?.makeFirstResponder(terminalView)
        resizeSessionToFitView()
        invalidateDisplay()
        if strictRespawn {
            // Every time: a new connection; the old scrollback is gone.
            terminalView.showToast(remote.reconnectNotice)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let notice = pendingSessionNotice {
            pendingSessionNotice = nil
            terminalView?.showToast(notice, kind: .warning)
        }
    }

    func applyFocusAppearance() {
        // One pane needs neither.
        let inSplit = splitController?.hasMultiplePanes == true
        // The dim is structural and stays while the app is inactive; ring and
        // highlight follow `hasUserFocus`, so cmd-tab leaves no false ring.
        focusDimView?.isHidden = isFocusedPane || !inSplit
        let highlighted = hasUserFocus && inSplit
        focusRingView?.isHidden = !highlighted
        focusHighlightView?.isHidden = !highlighted
        // The accent can change at runtime; Increase Contrast wants more.
        focusRingView?.layer?.borderColor = Self.focusRingColor.cgColor
        focusRingView?.layer?.borderWidth =
            SystemAccessibility.increaseContrast ? Self.focusRingWidth + 1 : Self.focusRingWidth
        reportFocusIfNeeded()
        if !hasUserFocus { stopCursorBlink(); inputSourceIndicator.view.isHidden = true }
        else { inputSourceIndicator.refreshSource() }
        invalidateDisplay()
    }

    /// Enough to tell panes apart, little enough to read through.
    static let unfocusedDim: CGFloat = 0.08
    /// A hairline; 2pt dominated small windows.
    static let focusRingWidth: CGFloat = 1
    /// Half-strength accent — full alpha was louder than the text it framed;
    /// full again under Increase Contrast.
    static var focusRingColor: NSColor {
        let accent = NSColor.controlAccentColor
        return SystemAccessibility.increaseContrast
            ? accent : accent.withAlphaComponent(focusRingAlpha)
    }

    static let focusRingAlpha: CGFloat = 0.5
    /// Stronger recoloured the text underneath.
    static let focusHighlightAlpha: CGFloat = 0.05
}

/// Input falls through to the terminal view.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
