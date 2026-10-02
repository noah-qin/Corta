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
import Synchronization

/// One pane: a `TerminalSession` and the renderer and view that draw it.
/// Knows no sibling panes beyond `splitController` (D07). This file owns
/// lifecycle, the session and the render loop; behaviour lives in the
/// `ViewController+<concern>.swift` extensions.
class ViewController: NSViewController {
    // Not `private`: extensions reach these and cannot add storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    /// Captured by each session's callbacks, so one from a session a retry has
    /// since replaced is a no-op — `[weak self]` only says the controller is
    /// alive, not that it is still this session's.
    private var sessionGeneration = 0
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
    var pinchAccumulator: CGFloat = 0
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
    /// For changes the damage diff cannot see: drawable size, scale, scrolling.
    private var needsRedraw = true
    /// `?2026` withheld a frame, so the next one presents even if the diff
    /// finds nothing.
    private var wasSynchronizedOutputActive = false
    /// An idle frame costs this one check, not a diff. One per session,
    /// replaced with it (`OutputWakeGate`).
    private var outputWake = OutputWakeGate()
    private var resizeDebouncer: ResizeDebouncer!
    private var cachedProcessName: String?
    private var cachedDirectory: String?
    /// `cachedDirectory` if it was a directory when it last changed: the
    /// title bar's proxy icon.
    private var representedDirectory: URL?
    private var directoryProbeGeneration = 0
    // At most two blocked filesystem probes process-wide. Admission does not
    // queue work: a hung mount must not grow a backlog of threads or closures.
    nonisolated private static let directoryProbes = Mutex(0)
    var directoryCheckerForTesting: (@Sendable (String) -> Bool)?
    private var cachedRemoteState: PaneRemoteState = .local
    /// Shared by both readers so they supersede the same report.
    private var remoteReportTracker = PaneRemoteState.ReportTracker()
    private var lastProcessFactsRefresh: CFTimeInterval = 0
    /// A title rebuild waiting out `processFactsInterval`; at most one, and
    /// cancelled by `teardown`.
    private var trailingTitleRefresh: DispatchWorkItem?
    private var isShowingTransientSize = false
    private var transientSizeReset: DispatchWorkItem?

    /// ⌘+/⌘− re-fit the window to keep this grid size.
    var lastRequestedSize: TerminalSize?

    let search = PaneSearchState()

    /// An O(scrollback) copy/export build, off the interaction path. Cancelling
    /// only stops its result being applied — the build runs to completion — and
    /// `largeTextTaskGeneration` keeps a late one from clearing its successor.
    var largeTextTask: Task<Void, Never>?
    var largeTextTaskGeneration = 0
    /// Test hook: a private pasteboard, so tests never touch the real one.
    var pasteboardForTesting: NSPasteboard?
    /// Test hook: holds the detached build, which has no scheduling barrier —
    /// otherwise "not landed yet" depends on the scheduler.
    var largeTextBuildGateForTesting: (@Sendable () -> Void)?
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
    /// and `UInt16(.infinity)` traps.
    nonisolated static func cellCount(_ quotient: CGFloat) -> UInt16 {
        guard quotient.isFinite else { return 1 }
        return UInt16(min(max(1, quotient), CGFloat(UInt16.max)))
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
            if strictRespawn, let command = reconnectCommand {
                started = StartedSession(
                    session: try respawn(command, size: initialSize, configuration: configuration),
                    notice: nil, executable: command.executable, arguments: command.arguments)
            } else {
                started = try Self.startSession(
                    size: initialSize, directory: inheritedWorkingDirectory,
                    scrollbackLimit: configuration.scrollbackLines,
                    commandHistoryLimit: configuration.commandHistoryLimit, preset: preset)
            }
        } catch {
            presentFailure(
                title: L10n.text("failure.title.session"),
                detail: Self.describe(error), canRetry: true,
                canReconnect: reconnectCommand.map {
                    PaneRemoteState.isRemoteLauncher(executable: $0.executable)
                } ?? false)
            return
        }
        session = started.session
        launchedCommand = (started.executable, started.arguments)
        sessionGeneration += 1
        invalidateProcessFacts()
        cachedRemoteState = .local
        remoteReportTracker = PaneRemoteState.ReportTracker()
        session.dynamicColors =
            AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
            .dynamicColors
        session.indexedPalette =
            AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
            .indexedPaletteDefaults
        pendingSessionNotice = started.notice
        lastRequestedSize = initialSize

        installPaneViews()
        installSessionCallbacks(generation: sessionGeneration)
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

    private func installSessionCallbacks(generation: Int) {
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session?.resize(to: size)
        }
        if !didInstallObservers {
            didInstallObservers = true
            observeWindowFocus()
            observeConfiguration()
        }
        let wake = OutputWakeGate()
        outputWake = wake
        taskNotifier.lastOutputUptimeNanoseconds = { wake.lastOutputUptimeNanoseconds }
        session.onOutput = { [weak self] in
            self?.noteOutput(generation: generation, wake: wake)
        }
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
            return render(drawableSize: drawableSize, drawable: drawable)
        }
        view.shouldRenderFrame = { [weak self] in
            self?.prepareFrame() ?? false
        }
        // `view` weakly too: the closure is stored on it, and a strong capture
        // kept every closed pane's view — and its drawables — alive.
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
        view.onDrawableSizeChange = { [weak self] in
            self?.invalidateDisplay()
        }
        view.onPaste = { [weak self] in
            self?.pasteFromClipboard()
        }
        view.onSearchKey = { [weak self] (event: NSEvent) -> Bool in
            self?.handleSearchKey(event) ?? false
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
        directoryProbeGeneration += 1
        trailingTitleRefresh?.cancel()
        trailingTitleRefresh = nil
        closeSearchBar()
        largeTextTask?.cancel()
        largeTextTask = nil
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

    /// Per vsync. With nothing new it reports nothing pending, which lets the
    /// scheduler pause (idle ~0% CPU, `PERFORMANCE.md` §3); otherwise the diff is
    /// cached for `render` and a frame happens only on damage.
    private func prepareFrame() -> Bool {
        guard let session, terminalRenderer != nil else { return false }
        if session.takeBell() {
            handleBell()
        }
        let hasOutput = outputWake.takePending()
        guard needsRedraw || hasOutput else { return false }
        // Title, directory and process all arrive as output, so this keeps the
        // window and tab title current without a timer. An unfocused pane's
        // applies on focus.
        if hasOutput, isFocusedPane {
            applyWindowTitle()
        }
        // Search refresh is a full-scrollback sweep; off the render path.
        if hasOutput, scrollOffset > 0, !sawOutputWhileScrolled {
            // Nothing else says so: no scroll bar, and the live screen is off view.
            sawOutputWhileScrolled = true
            updateScrollPositionIndicator()
        }
        if hasOutput, search.bar != nil {
            scheduleBackgroundSearchRefresh()
        }
        if hasOutput {
            // Rate-limited and gated on VoiceOver inside the call.
            terminalView?.noteAccessibilityValueChanged()
            drainClipboardRequests()
            let finished = session.takeFinishedCommand()
            // The prompt's return is the moment the program left: the title
            // names the shell again now, not an interval later.
            if finished != nil, isFocusedPane {
                invalidateProcessFacts()
                applyWindowTitle()
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
        if session.isSynchronizedOutputEnabled {
            // Owe a present until the DECRST, or a torn state shows.
            wasSynchronizedOutputActive = true
            return false
        }
        let forced = needsRedraw || wasSynchronizedOutputActive
        needsRedraw = false
        wasSynchronizedOutputActive = false
        let grid = session.snapshot()
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
        let mappedSearchMatches = search.matches.map { TerminalSelection($0, grid: grid) }
        let indexedPalette = session.indexedPalette
        let damaged = terminalRenderer.updateInstances(
            grid: grid, scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0 && isFocusedPane, selection: selection,
            searchMatches: mappedSearchMatches,
            currentSearchMatchIndex: search.currentMatchIndex, hoveredLink: hoveredLink,
            indexedOverrides: indexedPalette.overrides,
            indexedOverridesGeneration: indexedPalette.overridesGeneration)
        return forced || damaged
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

    /// On the reader thread, per parse batch; `generation` guards against a
    /// replaced session. Hops to the main actor only when `wake` was idle:
    /// the frame that takes the flag re-arms it, so a flood costs one hop a
    /// frame, not one a batch.
    nonisolated private func noteOutput(generation: Int, wake: OutputWakeGate) {
        // A point, not an interval: the interval began on another thread.
        InputLatencySignposts.emit(.output)
        RenderMetrics.noteOutputForKeystroke()
        guard wake.noteOutput() else { return }
        // Measured apart: a busy main thread lengthens this stage.
        let interval = InputLatencySignposts.begin(.wake)
        // On the keypress-to-pixel chain; the default priority has no claim.
        Task(priority: .userInitiated) { @MainActor [weak self] in
            InputLatencySignposts.end(.wake, interval)
            guard let self, self.sessionGeneration == generation else { return }
            self.terminalView?.setNeedsRedraw()
        }
    }

    /// A child that exited on its own. A user's close set `didTeardown` before
    /// stopping the session, and must not toast; a generation check alone
    /// would miss it.
    @MainActor
    private func noteChildExit(_: ChildExit, generation: Int) {
        guard !didTeardown, sessionGeneration == generation else { return }
        // A dead child produces no output to rebuild the title; the `⟂ host`
        // badge would outlive its connection.
        invalidateProcessFacts()
        applyWindowTitle()
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
        needsRedraw = true
        terminalView?.setNeedsRedraw()
    }

    func resizeSessionToFitView() {
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
        let columns = UInt16(max(1, usable.width / terminalRenderer.pointMetrics.cellWidth))
        let rows = UInt16(max(1, usable.height / terminalRenderer.pointMetrics.cellHeight))
        let pixels = pixelSize(columns: Int(columns), rows: Int(rows), metrics: terminalRenderer.metrics)
        let size = TerminalSize(
            rows: rows, columns: columns, pixelWidth: pixels.width, pixelHeight: pixels.height)
        guard size != lastRequestedSize else { return }
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
        resizeDebouncer.resize(to: size, coalesce: true)
        // The title shows the live size, as Terminal.app does.
        if isFocusedPane {
            invalidateProcessFacts()
            noteTransientSizeChange()
            applyWindowTitle()
        }
    }

    // MARK: - Window title

    /// `⟂ host — <title or directory> — <process> — <columns>×<rows>`, as
    /// Terminal.app shows; unknown parts are left out. The host badge leads — it
    /// answers which computer the rest is on. An OSC 0/2 title beats the
    /// directory. Every part but the size is child input: capped and stripped of
    /// controls (`SECURITY.md` §2).
    var composedWindowTitle: String {
        guard session != nil else { return "Corta" }
        refreshProcessFactsIfStale()
        var parts: [String] = []
        // The badge's host and directory are the remote shell's own OSC 7
        // text, percent-decoded — as hostile as any other child-supplied
        // component, and sanitised the same way.
        if let badge = Self.sanitizedTitleComponent(cachedRemoteState.titleComponent) {
            parts.append(badge)
        }
        if let title = Self.sanitizedTitleComponent(session.windowTitle) {
            parts.append(title)
        } else if let directory = Self.sanitizedTitleComponent(cachedDirectory.map(Self.abbreviated)) {
            // OSC 7 text too: a directory named with a newline or a bidi
            // override would otherwise reach the title as it is.
            parts.append(directory)
        }
        if let process = Self.sanitizedTitleComponent(cachedProcessName) {
            parts.append(process)
        }
        // The grid size, only while it is changing.
        //
        // Appended permanently, the title would read "~/Corta — zsh —
        // 120×27" for the whole life of the window: a third of the space,
        // and with tabs a third of every tab label, spent on a number that
        // is interesting for the two seconds of a drag and never again.
        // Terminal.app shows it during a resize for exactly that reason.
        // With tabs the cost is worse than cosmetic — the tab label
        // truncates from the right, so the directory or task name the user
        // is actually distinguishing tabs by would be the first thing to
        // disappear.
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
    /// user can drag into another application. A remote pane gets no icon at
    /// all, by construction rather than by check: `cachedDirectory` reads
    /// `session.currentDirectory`, which a remote `OSC 7` report never
    /// reaches (it lands in `remoteContext`), so there is no remote
    /// path here to offer a drag of.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        let title = composedWindowTitle
        if window.title != title { window.title = title }

        if window.representedURL != representedDirectory {
            window.representedURL = representedDirectory
        }
    }

    /// OSC 7 paths can point at an unresponsive network mount. Never stat on
    /// the main actor, and never publish a result for a superseded path.
    func probeRepresentedDirectory(_ path: String?) {
        directoryProbeGeneration += 1
        let generation = directoryProbeGeneration
        representedDirectory = nil
        guard let path else { return }
        let admitted = Self.directoryProbes.withLock { active in
            guard active < 2 else { return false }
            active += 1
            return true
        }
        guard admitted else { return }
        let checker = directoryCheckerForTesting
        Task.detached(priority: .utility) { [weak self] in
            let exists: Bool
            if let checker {
                exists = checker(path)
            } else {
                var isDirectory: ObjCBool = false
                exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            Self.directoryProbes.withLock { $0 -= 1 }
            await MainActor.run { [weak self] in
                guard let self, !self.didTeardown,
                    generation == self.directoryProbeGeneration else { return }
                self.representedDirectory = exists ? URL(fileURLWithPath: path) : nil
                self.applyWindowTitle()
            }
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

    /// The process name, directory and remote state behind the title, and
    /// when they were last read.
    ///
    /// All three are syscalls — `tcgetpgrp`, `proc_name`, `proc_pidinfo` —
    /// and the title is rebuilt on every output batch, which during a `yes`
    /// or a build is thousands of batches a second. Refreshed on an interval
    /// instead: a directory that changed a quarter of a second ago is not
    /// worth three syscalls per frame, and the OSC 0/2 title (the part a
    /// program updates deliberately) is read fresh every time regardless.
    /// The remote state rides the same cadence: `ssh` starting or
    /// exiting announces itself with output — the far end's banner, the
    /// local shell's returning prompt — so the badge follows within one
    /// interval, with no timer of its own.
    private func refreshProcessFactsIfStale() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastProcessFactsRefresh
        guard elapsed >= Self.processFactsInterval else {
            scheduleTrailingTitleRefresh(after: Self.processFactsInterval - elapsed)
            return
        }
        lastProcessFactsRefresh = now
        cachedProcessName = session.activeProcessName
        let directory = session.currentDirectory
        if directory != cachedDirectory {
            cachedDirectory = directory
            probeRepresentedDirectory(directory)
        }
        cachedRemoteState = resolveRemoteState()
    }

    /// One fresh read of the pane's remote state — the syscalls, the
    /// spawn record and the stale-report mask together. Both readers
    /// (`refreshProcessFactsIfStale`, `paneRemoteState`) come through here
    /// so a report one of them saw the pane local behind is superseded for
    /// the other too.
    func resolveRemoteState() -> PaneRemoteState {
        remoteReportTracker.resolve(
            remoteContext: session.remoteContext,
            hasForegroundJob: session.hasForegroundJob,
            foregroundProcessName: session.foregroundProcessName,
            childIsRemoteLauncher: childIsLiveRemoteLauncher)
    }

    /// One more title rebuild once the interval has passed. A skipped refresh
    /// is only stale if nothing follows it, and a program that exits and hands
    /// back the prompt within the interval is followed by nothing: without
    /// this, `kitten icat` left "— kitten" in the title until the next output.
    private func scheduleTrailingTitleRefresh(after delay: CFTimeInterval) {
        guard trailingTitleRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            trailingTitleRefresh = nil
            // An unfocused pane's title applies on focus.
            guard !didTeardown, isFocusedPane else { return }
            applyWindowTitle()
        }
        trailingTitleRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// On focus and command boundaries, where waiting out the interval would
    /// show something stale.
    func invalidateProcessFacts() {
        lastProcessFactsRefresh = 0
    }

    private static let processFactsInterval: CFTimeInterval = 0.4

    /// No controls (a newline truncates a title) and a hard length cap.
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

    /// `~/Developer`, or just the last name deeper down; the proxy icon has the
    /// full path.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Right after `prepareFrame()` in the same callback, drawing its cached
    /// context; never blocks the reader (`PERFORMANCE.md` §2.1). Draws the
    /// renderer's cached instances, which `prepareFrame` last diffed, as one
    /// Metal 4 render pass; the backend commits and presents the drawable.
    /// Returns false for a frame the backend dropped, which the scheduler
    /// owes another tick.
    private func render(drawableSize: CGSize, drawable: CAMetalDrawable) -> Bool {
        guard let terminalRenderer else {
            // Never hold a drawable: an unpresented one is never recycled.
            drawable.present()
            return true
        }
        let rect = Self.contentRect(
            in: drawableSize, scale: terminalRenderer.scale,
            gridHeight: CGFloat(terminalRenderer.cachedRowCount) * terminalRenderer.metrics.cellHeight,
            topInset: topInset)
        let gpu = InputLatencySignposts.begin(.gpu)
        let gpuStart = RenderMetrics.isEnabled ? DispatchTime.now() : nil
        // `gpu` spans submission to completion — the only place GPU time and a
        // drawable wait become visible.
        let onCompleted: (@Sendable ((any Error)?) -> Void)? =
            (gpu != nil || gpuStart != nil)
            ? { @Sendable _ in
                InputLatencySignposts.end(.gpu, gpu)
                if let gpuStart {
                    let ms =
                        Double(DispatchTime.now().uptimeNanoseconds - gpuStart.uptimeNanoseconds)
                        / 1_000_000
                    RenderMetrics.record(.gpu, milliseconds: ms)
                }
            }
            : nil
        let background = TerminalColorPalette.clearColor
        let commit = InputLatencySignposts.begin(.commit)
        let drawn = terminalRenderer.draw(
            rect: rect, drawableSize: drawableSize, target: drawable.texture,
            clearColor: MTLClearColorMake(
                Double(background.x), Double(background.y), Double(background.z),
                Double(background.w)),
            // For Metal System Trace: ties a command buffer to its pane.
            drawable: drawable, label: "Corta.frame.\(ObjectIdentifier(self).hashValue)",
            onCompleted: onCompleted)
        InputLatencySignposts.end(.commit, commit)
        return drawn
    }

    /// Top-anchored when the grid fits, so the rounding remainder sits at the
    /// bottom, not under the titlebar; bottom-anchored when mid-drag the grid is
    /// taller, so the prompt stays put (top-pinning was the "text jumps").
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
        configuredShell: String? = nil
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
                    environment: environment, size: size,
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
            environment: environment, size: size,
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
        failure.onReconnect = { [weak self] in self?.reconnectRemote(nil) }
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
            terminalView.showToast(reconnectNotice)
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
