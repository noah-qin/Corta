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
import CortaPOSIX
import CortaTerminal
import Metal

/// One pane: a `TerminalSession` and the renderer and view that draw it.
/// Knows no sibling panes beyond `splitController` (D07). The pane keeps
/// the session, the view, the renderer, sizing, teardown and the wiring
/// between them; each other concern is a collaborator it composes
/// (`docs/DESIGN.md` §4.1), and new behaviour is added as one.
class ViewController: NSViewController, PaneSearchHost, PaneRemoteHost, PaneCommandsHost,
    PaneFocusHost, PanePointerHost, PaneShellIntegrationHost, PaneAppearanceHost,
    PaneSessionEndHost, NSMenuItemValidation
{
    // Not `private`: extensions reach these and cannot add storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    private var readerDemotion: DispatchWorkItem?
    private var readerHiddenSince: TimeInterval?
    private var readerLastInput: TimeInterval?

    func updateReaderPriority(input: Bool = false) {
        guard let session, !didTeardown else { return }
        readerDemotion?.cancel()
        readerDemotion = nil
        let now = ProcessInfo.processInfo.systemUptime
        if input { readerLastInput = now }
        let window = view.window
        let visible =
            window?.occlusionState.contains(.visible) == true && !view.isHiddenOrHasHiddenAncestor
        let selected = window?.tabGroup.map { $0.selectedWindow === window } ?? true
        if visible && selected {
            readerHiddenSince = nil
        } else if readerHiddenSince == nil {
            readerHiddenSince = now
        }
        let priority = ReaderPriorityPolicy.priority(
            visible: visible, selected: selected,
            hiddenSince: readerHiddenSince, lastInput: readerLastInput, now: now)
        session.setReaderPriority(priority)
        if priority == .interactive, !(visible && selected) {
            let work = DispatchWorkItem { [weak self] in self?.updateReaderPriority() }
            readerDemotion = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ReaderPriorityPolicy.grace, execute: work)
        }
    }

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
    /// Family, weight and drawing options. Kept to tell a style change from
    /// a size change.
    var fontStyle = FontStyle()
    let taskNotifier = TaskNotifier()
    /// `font-size`'s default, for a MacBook's built-in Retina display.
    static let defaultFontSize: CGFloat = 13
    /// Set before the view loads for a split, so the shell's first output is
    /// laid out at the right width, not reflowed.
    var inheritedWorkingDirectory: String?
    var initialGridSize: TerminalSize?

    /// Applied once at spawn; set before the view loads.
    var preset: Preset?
    /// What actually spawned — after a fallback, not what was asked for. The
    /// remote-state composition and Reconnect read it.
    private(set) var launchedCommand: (executable: String, arguments: [String])?
    /// `PaneSpawn.Started.bootstrapFolder` of the current session.
    private var bootstrapFolder: URL?
    var scrollOffset = 0 {
        didSet {
            guard scrollOffset != oldValue else { return }
            shell.selectedCommandID = nil
            if scrollOffset == 0 {
                sawOutputWhileScrolled = false
                scrollAnchorTotalPushed = nil
            } else {
                // Including `prepareFrame`'s own shift, so the next batch's growth is
                // measured from there.
                scrollAnchorTotalPushed = session?.scrollbackTotalPushed
            }
            pointer.updateScrollPositionIndicator()
            search.placeClearOfContent()
        }
    }

    /// The total the offset was set against; `nil` at the bottom.
    /// `prepareFrame` keeps the viewport on the same document row with it.
    var scrollAnchorTotalPushed: Int?

    /// The fact a person scrolled up to wait for.
    var sawOutputWhileScrolled = false
    var selection: TerminalSelection?
    /// Non-nil exactly when `isOperable` is false.
    var failureView: PaneFailureView?
    /// Shown from the moment this pane's session ends until a new one
    /// starts or the pane closes (`SessionEndedBar`).
    private(set) lazy var sessionEnd = PaneSessionEnd(host: self)
    var sessionEndedBar: SessionEndedBar? { sessionEnd.bar }
    /// A fallback shell or directory, reported once the toast can be seen.
    private var pendingSessionNotice: String?
    /// The window is sized (`SplitViewController.prepareWindow`); until then a
    /// layout runs at a placeholder size and must not reach the child
    /// (`resizeSessionToFitView`).
    var didSizeWindow = false
    private var resizeDebouncer: ResizeDebouncer!

    /// ⌘+/⌘− re-fit the window to keep this grid size.
    var lastRequestedSize: TerminalSize?

    /// Scrollback search: the bar, its sweeps and the highlighted matches.
    private(set) lazy var search = PaneSearch(host: self)
    /// Whether this pane talks to another machine, Reconnect, remote
    /// references and the SFTP browser's entry.
    private(set) lazy var remote = PaneRemote(host: self)
    /// Font size, copy and export, drops and Services, Finder actions and
    /// app-initiated `cd`.
    private(set) lazy var commands = PaneCommands(host: self)
    /// The dim, ring and highlight, the cursor's blink, and `?1004`.
    private(set) lazy var focus = PaneFocus(host: self)
    /// Scrolling, mouse selection, links and local file references.
    private(set) lazy var pointer = PanePointer(host: self)
    /// OSC 133's jumps, command output, history fill, the status marks and
    /// directory completion, and the OSC 52 drain.
    private(set) lazy var shell = PaneShellIntegration(host: self)
    /// The configuration file and the live appearance followed, and the
    /// font's size, family and backing scale applied.
    private(set) lazy var appearance = PaneAppearance(host: self)
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
    var chromeOverlap: CGFloat {
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
    var isOperable: Bool { failureView == nil && terminalRenderer != nil && session != nil }

    /// An estimate when the renderer failed, so a broken pane cannot take the
    /// window's layout down.
    private var cellMetrics: (cellWidth: CGFloat, cellHeight: CGFloat) {
        if let terminalRenderer {
            let metrics = terminalRenderer.pointMetrics
            return (metrics.cellWidth, metrics.cellHeight)
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: TerminalFont.systemWeight)
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
    /// Also the grid `resizeSessionToFitView` sends, so a prediction and the
    /// session never disagree. Half a point of slack: a window fitted to
    /// whole cells can land a rounding step short of the last one, and the
    /// right and bottom insets absorb the overhang.
    func gridSize(fitting size: CGSize) -> TerminalSize {
        let metrics = cellMetrics
        let usable = usableSize(fitting: size)
        return TerminalSize(
            rows: Self.cellCount((usable.height + Self.fitSlack) / metrics.cellHeight),
            columns: Self.cellCount((usable.width + Self.fitSlack) / metrics.cellWidth))
    }

    /// The area of a pane `size` large that the grid may use: the size less
    /// the insets.
    func usableSize(fitting size: CGSize) -> CGSize {
        CGSize(width: size.width - TerminalLayout.insetWidth, height: size.height - verticalInsets)
    }

    nonisolated static let fitSlack: CGFloat = 0.5

    /// Clamped before converting: a zero metric makes the quotient infinite,
    /// and `UInt16(.infinity)` traps.
    nonisolated static func cellCount(_ quotient: CGFloat) -> UInt16 {
        guard quotient.isFinite else { return 1 }
        return UInt16(min(max(1, quotient), CGFloat(UInt16.max)))
    }

    /// The window's frame size for the initial grid, so the session is born at
    /// its final size: the content covers the whole frame
    /// (`.fullSizeContentView`), so the chrome is part of it. Whole chrome,
    /// not `topInset`: before constraints settle, the root pane can look as if
    /// it does not touch the top.
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
        fontSize = Configuration.fontSizeRange.clamped(configuration.fontSize)
        fontStyle = FontStyle(configuration)
        guard prepareRenderer() else { return }
        let initialSize = initialTerminalSize()
        guard let started = startSession(strictRespawn: strictRespawn, size: initialSize, configuration: configuration)
        else { return }
        adopt(started, size: initialSize)
        // Before the reader starts, so the shell's first output is measured
        // the way the configuration says.
        session.ambiguousWidthIsWide = configuration.ambiguousWidth == .wide
        installPaneViews()
        installSessionCallbacks()
        installTerminalCallbacks(on: terminalView)
        // The PTY reader must not run until all callbacks and views are ready.
        session.start()
    }

    /// A Metal 4 device and a renderer for it, or the failure view saying
    /// why not.
    private func prepareRenderer() -> Bool {
        guard let device = self.device ?? MTLCreateSystemDefaultDevice() else {
            presentFailure(
                title: L10n.text("failure.title.metal"),
                detail: L10n.text("failure.detail.metal"), canRetry: false)
            return false
        }
        // Metal 4 is the only renderer (D21). A GPU without it — a virtual
        // machine's — gets this pane and no session, not a fallback.
        guard Metal4Backend.isSupported(by: device) else {
            presentFailure(
                title: L10n.text("failure.title.metal4"),
                detail: L10n.text("failure.detail.metal4"), canRetry: false)
            return false
        }
        self.device = device
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        do {
            terminalRenderer = try makeRenderer(device: device, scale: scale)
            return true
        } catch {
            presentFailure(
                title: L10n.text("failure.title.renderer"),
                detail: PaneSpawn.describe(error), canRetry: true)
            return false
        }
    }

    /// The grid the child starts with, and its size in pixels.
    private func initialTerminalSize() -> TerminalSize {
        let size = initialGridSize ?? configuredGridSize
        guard let terminalRenderer else { return size }
        let pixels = pixelSize(
            columns: Int(size.columns), rows: Int(size.rows), metrics: terminalRenderer.metrics)
        return TerminalSize(
            rows: size.rows, columns: size.columns, pixelWidth: pixels.width, pixelHeight: pixels.height)
    }

    /// The pane's child: the remote command again on a strict respawn,
    /// otherwise the shell or preset. `nil` after presenting why it failed.
    private func startSession(
        strictRespawn: Bool, size: TerminalSize, configuration: Configuration
    ) -> PaneSpawn.Started? {
        do {
            if strictRespawn, let command = remote.reconnectCommand {
                return try PaneSpawn.respawn(
                    command, size: size, configuration: configuration, preset: preset,
                    workingDirectory: inheritedWorkingDirectory)
            }
            return try PaneSpawn.start(
                size: size, directory: inheritedWorkingDirectory,
                scrollbackLimit: configuration.scrollbackLines,
                commandHistoryLimit: configuration.commandHistoryLimit, preset: preset,
                directoryCompletion: configuration.directoryCompletion)
        } catch {
            presentFailure(
                title: L10n.text("failure.title.session"),
                detail: PaneSpawn.describe(error), canRetry: true,
                canReconnect: remote.reconnectCommand.map {
                    PaneRemoteState.isRemoteLauncher(executable: $0.executable)
                } ?? false)
            return nil
        }
    }

    /// Makes `started` this pane's session, coloured by the current theme.
    private func adopt(_ started: PaneSpawn.Started, size: TerminalSize) {
        session = started.session
        removeBootstrapFolder()
        bootstrapFolder = started.bootstrapFolder
        launchedCommand = (started.executable, started.arguments)
        windowTitle.reset(session: started.session)
        remote.reset()
        let variant = AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
        session.dynamicColors = variant.dynamicColors
        session.indexedPalette = variant.indexedPaletteDefaults
        pendingSessionNotice = started.notice
        lastRequestedSize = size
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
        focus.installViews(in: self.view)
    }

    private func installSessionCallbacks() {
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            self?.session?.resize(to: size)
        }
        // Each is idempotent: a retry's second setup observes nothing twice.
        focus.observeWindows()
        appearance.observe()
        let generation = frameLoop.attach(session: session, renderer: terminalRenderer)
        taskNotifier.sessionGeneration = generation
        let wake = frameLoop.outputWake
        taskNotifier.lastOutputUptimeNanoseconds = { wake.lastOutputUptimeNanoseconds }
        taskNotifier.title = { [weak self] in self?.windowTitle.notificationTitle ?? "Corta" }
        session.onChildExit = { [weak self] childExit in
            Task(priority: .userInitiated) { @MainActor in
                self?.noteChildExit(childExit, generation: generation)
            }
        }
        session.onIOFailure = { [weak self] failure in
            Task(priority: .userInitiated) { @MainActor in
                guard let self, !self.didTeardown, self.frameLoop.isCurrent(generation) else { return }
                let reconnect = self.remote.reconnectCommand.map {
                    PaneRemoteState.isRemoteLauncher(executable: $0.executable)
                } ?? false
                self.frameLoop.suspendRendering()
                self.terminalView?.stopRendering()
                self.presentFailure(title: L10n.text("failure.title.runtimeSession"),
                    detail: "\(failure.description)\n\n\(L10n.text("failure.runtimeHint"))",
                    canRetry: !reconnect, canReconnect: reconnect, takesFocus: self.isFocusedPane)
            }
        }
    }

    private func installTerminalCallbacks(on view: TerminalView) {
        frameLoop.install(on: view)
        pointer.install(on: view)
        installInputSourceIndicator(on: view)
        view.onCompletionKey = { [weak self] event in self?.shell.handleDirectoryCompletionKey(event) ?? false }
        // `view` weakly too: the closure is stored on it, and a strong capture
        // kept every closed pane's view — and its drawables — alive.
        view.onKeyBytes = { [weak self, weak view] bytes in
            self?.sendKeyBytes(bytes, from: view)
        }
        installKeyboardModes(on: view)
        commands.installNativeIntegrations(on: view)
        installViewEvents(on: view)
    }

    private func installInputSourceIndicator(on view: TerminalView) {
        view.addSubview(view.shellOverlay)
        view.addSubview(inputSourceIndicator.view)
        inputSourceIndicator.onChange = { [weak self] in self?.invalidateDisplay() }
        view.onInputContextChange = { [weak self, weak view] in
            guard let self, let view else { return }
            if view.window?.firstResponder !== view { inputSourceIndicator.view.isHidden = true }
            invalidateDisplay()
        }
        inputSourceIndicator.start()
    }

    /// A keystroke's bytes, to the child.
    private func sendKeyBytes(_ bytes: [UInt8], from view: TerminalView?) {
        guard isOperable else { return }
        // Reader priority was raised by the view's `noteUserInput`, and
        // by the session's own write.
        if bytes.contains(0x0D) { taskNotifier.noteCommandSubmitted(in: view?.window) }
        pointer.returnToBottomOnInput()
        // Ctrl-C under a large paste: queued behind it, the interrupt
        // waited for the whole paste — or, past the back-pressure cap,
        // was refused. It drops what is left of the paste and goes next,
        // or, with a write blocked on a child not reading, is delivered
        // as the signal the terminal would raise for it.
        if Paste.isInterrupt(bytes) {
            let interrupt = session.interruptPendingPaste()
            if interrupt.cancelledPaste {
                view?.showToast(L10n.text("toast.pasteCancelled"), kind: .warning)
            }
            if interrupt.signalled { return }
        }
        switch session.write(bytes) {
        case .accepted, .failed: break // An async failure has its persistent recovery UI.
        case .backpressured:
            view?.showToast(L10n.text("toast.inputBackpressured"), kind: .warning)
        case .stopped:
            view?.showToast(L10n.text("toast.shellExited"), kind: .warning)
        }
    }

    /// What the key encoder asks per keystroke: the terminal's modes and
    /// the settings that change what a key sends.
    private func installKeyboardModes(on view: TerminalView) {
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
    }

    private func installViewEvents(on view: TerminalView) {
        view.onLiveResizeEnded = { [weak self] in
            self?.endLiveResize()
        }
        view.onBackingScaleChange = { [weak self] scale in
            self?.appearance.rebuildAtlas(forBackingScale: scale)
        }
        view.onDrawableSizeChange = { [weak self] in
            self?.invalidateDisplay()
        }
        view.onSearchKey = { [weak self] (event: NSEvent) -> Bool in
            self?.search.handleKey(event) ?? false
        }
        view.cellSize = CGSize(width: terminalRenderer.pointMetrics.cellWidth, height: terminalRenderer.pointMetrics.cellHeight)
        view.preeditFontProvider = { [weak self] in
            guard let self else {
                return NSFont.monospacedSystemFont(
                    ofSize: ViewController.defaultFontSize, weight: TerminalFont.systemWeight)
            }
            return fontStyle.font(ofSize: fontSize) as NSFont
        }
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.inputSourceIndicator.refreshSource()
            self.splitController?.noteFocus(self)
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
        focus.stop()
        inputSourceIndicator.stop()
        windowTitle.stop()
        search.close()
        commands.stop()
        taskNotifier.cancel()
        remote.cancelPendingOpens()
        appearance.stop()
        frameLoop.suspendRendering()
        terminalView?.stopRendering()
        session?.stop()
        removeBootstrapFolder()
    }

    /// The zsh wrappers the current session started from, gone with it.
    private func removeBootstrapFolder() {
        if let bootstrapFolder { ZshBootstrap.remove(bootstrapFolder) }
        bootstrapFolder = nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Size or scale can change with no grid change the diff would see.
        invalidateDisplay()
        resizeSessionToFitView()
        focus.updateLayout()
        search.placeClearOfContent()
    }

    private func makeFrameLoop() -> PaneFrameLoop {
        let loop = PaneFrameLoop()
        loop.onBell = { [weak self] in self?.handleBell() }
        loop.onOutputBatch = { [weak self] in self?.noteOutputBatch() }
        loop.content = { [weak self] hasOutput in self?.frameContent(hasOutput: hasOutput) }
        loop.onNeedsDisplay = { [weak self] in self?.terminalView?.setNeedsRedraw() }
        loop.onRenderingFailure = { [weak self] error in
            guard let self, !self.didTeardown, self.failureView == nil else { return }
            Metal4Diagnostics.reportCommitFault(error)
            self.frameLoop.suspendRendering()
            self.terminalView?.stopRendering()
            let reconnect = self.remote.reconnectCommand.map {
                PaneRemoteState.isRemoteLauncher(executable: $0.executable)
            } ?? false
            self.presentFailure(title: L10n.text("failure.title.runtimeRenderer"),
                detail: L10n.text("failure.runtimeHint"),
                canRetry: !reconnect, canReconnect: reconnect, takesFocus: self.isFocusedPane)
        }
        loop.cursorHandoffSignal = focus.handoffSignal
        loop.onPresented = { [weak self] in
            self?.focus.framePresented(token: $0)
        }
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
            pointer.updateScrollPositionIndicator()
        }
        // Search refresh is a full-scrollback sweep; off the render path.
        if search.bar != nil {
            search.scheduleBackgroundRefresh()
            // The cursor may have moved under the bar.
            search.placeClearOfContent()
        }
        // Rate-limited and gated on VoiceOver inside the call.
        terminalView?.noteAccessibilityValueChanged()
        shell.drainClipboardRequests()
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

    /// Main-thread effects consume the frame snapshot, independently of GPU work.
    private func afterFrame(
        grid: Grid, hasOutput: Bool, cursorRevision: UInt64? = nil,
        inputMetadata: RenderInputSourceMetadata? = nil
    ) {
        guard session != nil, let terminalRenderer, terminalView != nil else { return }
        terminalView.refreshInputCompositionGeometry()
        let configuration = ConfigurationStore.shared.configuration
        splitController?.placeInputSourceIndicator(from: self, configuration: configuration)
        // Once per frame, for every overlay on the canvas.
        let canvas = CanvasTextColors.current
        shell.updateShellOverlay(grid: grid, canvas: canvas)
        pointer.dropSelectionIfRewritten(in: grid)
        if let inputMetadata, !terminalView.directPresentation.contains(.overlays) {
            let metrics = terminalRenderer.pointMetrics
            inputSourceIndicator.update(
                grid: grid, hasIntegration: inputMetadata.hasIntegration,
                promptRow: inputMetadata.promptRow,
                focused: focus.hasUserFocus && view.window?.firstResponder === terminalView,
                scrollOffset: scrollOffset, configuration: configuration, canvas: canvas,
                cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                topInset: topInset, compositionRect: terminalView.inputCompositionRect,
                blockedRects: terminalView.shellOverlay.occupiedRects + (search.bar.map { [$0.frame] } ?? []))
        } else if !inputSourceIndicator.view.isHidden { inputSourceIndicator.view.isHidden = true }
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
        let cursorStyle = focus.effectiveCursorStyle(grid: grid)
        focus.updateCursorBlink(grid: grid, style: cursorStyle, reset: hasOutput, outputRevision: cursorRevision)
    }

    private func renderInputs() -> RenderInputs {
        let config = ConfigurationStore.shared.configuration
        return RenderInputs(
            scrollOffset: scrollOffset,
            cursorVisible: scrollOffset == 0 && isFocusedPane
                && terminalView?.hasMarkedText() != true
                && sessionEndedBar == nil,
            cursorBlinkVisible: focus.cursorBlinkVisible,
            selection: selection,
            searchMatches: search.highlights,
            currentSearchMatchIndex: search.currentMatchIndex, hoveredLink: pointer.hoveredLink,
            drawsCommandMarks: config.commandStatusMarks)
    }

    private func frameContent(hasOutput: Bool) -> PaneFrameLoop.Content? {
        guard let session, let terminalRenderer else { return nil }
        let revision = focus.handoffSignal.snapshot.outputRevision
        let inputSnapshot =
            ConfigurationStore.shared.configuration.inputSourceIndicator != .off
            ? session.inputLineSnapshot() : nil
        let grid = inputSnapshot?.grid ?? session.snapshot()
        let metadata = inputSnapshot.map {
            RenderInputSourceMetadata(
                hasIntegration: $0.hasIntegration, promptRow: $0.promptRow)
        }
        afterFrame(
            grid: grid, hasOutput: hasOutput, cursorRevision: revision, inputMetadata: metadata)
        let inputs = renderInputs()
        terminalRenderer.drawsCommandMarks = inputs.drawsCommandMarks
        return PaneFrameLoop.Content(
            grid: grid, scrollOffset: inputs.scrollOffset,
            cursorVisible: inputs.cursorVisible && grid.isCursorVisible
                && inputs.cursorBlinkVisible,
            selection: inputs.selection, searchMatches: inputs.searchMatches,
            currentSearchMatchIndex: inputs.currentSearchMatchIndex,
            hoveredLink: inputs.hoveredLink,
            cursorStyle: focus.effectiveCursorStyle(grid: grid))
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
    private func noteChildExit(_ exit: ProcessExit, generation: Int) {
        guard !didTeardown, frameLoop.isCurrent(generation) else { return }
        // A dead child produces no output to rebuild the title; the `Remote: host`
        // badge would outlive its connection.
        windowTitle.invalidateProcessFacts()
        windowTitle.apply()
        // A remote launcher: the connection ended, and the way back is a new one.
        let isConnection =
            launchedCommand.map { PaneRemoteState.isRemoteLauncher(executable: $0.executable) }
            ?? false
        sessionEnd.present(exit, isConnection: isConnection)
    }

    func closeEndedPane() {
        if let split = splitController, split.hasMultiplePanes {
            split.closePane(self)
        } else {
            view.window?.performClose(nil)
        }
    }

    /// For local changes that produce no output.
    func invalidateDisplay() {
        focus.noteCursorActivity()
        updateReaderPriority()
        frameLoop.invalidate()
    }

    func refreshFocusAppearance() { focus.applyAppearance() }

    /// The grid now, or nil for a failed pane.
    func snapshot() -> Grid? {
        session?.snapshot()
    }

    func selectedText() -> String? {
        commands.selectedText()
    }

    func setFontSize(_ newSize: CGFloat, settle: Bool = true) {
        appearance.setFontSize(newSize, settle: settle)
    }

    func settleFontChange() { appearance.settleFontChange() }

    /// What copy, export and open-reference act on (`PaneShellIntegration`).
    var effectiveCommand: CommandRecord? { shell.effectiveCommand }

    /// ⌘A: `NSResponder` declares it, so the pane overrides rather than
    /// forwards.
    override func selectAll(_ sender: Any?) { pointer.selectAll(sender) }

    // MARK: - Forwarding

    /// Menu items, the palette, key bindings and AppKit's own items send their
    /// actions to the first responder or to the pane by name; the pane
    /// answers for the collaborator that implements each, through the
    /// Objective-C runtime's forwarding, and `validateMenuItem` asks it too.
    /// A collaborator's new `@objc` action needs nothing here; a new
    /// collaborator that owns actions joins both lists, in the same order
    /// (`PaneCommandsTests` holds them equal). `focus` and `appearance` have
    /// only notification selectors and stay out.
    /// Main-actor classes, so `Sendable`: `forwardingTarget(for:)` can carry
    /// one out of its `assumeIsolated`.
    var actionOwners: [any NSObject & Sendable] { [search, remote, commands, pointer, shell] }
    /// The same owners as classes, for a question that may come from any
    /// thread and so must not touch the instances.
    nonisolated static let actionOwnerClasses: [NSObject.Type] = [
        PaneSearch.self, PaneRemote.self, PaneCommands.self, PanePointer.self,
        PaneShellIntegration.self,
    ]

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        guard let aSelector else { return false }
        return Self.actionOwnerClasses.contains { $0.instancesRespond(to: aSelector) }
    }

    /// Every owner of an item's action gets its say; one that does not own
    /// it answers yes.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        actionOwners.allSatisfy {
            ($0 as? NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
        }
    }

    /// Only what the pane itself does not answer: `NSObject`'s and
    /// `NSResponder`'s own selectors stay the pane's. Actions are sent on the
    /// main thread; one sent from another would not be forwarded, and the
    /// runtime would report the selector unrecognised.
    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let aSelector, Thread.isMainThread else {
            return super.forwardingTarget(for: aSelector)
        }
        let owner = MainActor.assumeIsolated {
            actionOwners.first { $0.responds(to: aSelector) }
        }
        return owner ?? super.forwardingTarget(for: aSelector)
    }

    /// `coalesce: false` delivers the size now: a font change is one step,
    /// and waiting out the drag debounce drew a frame of the new font over
    /// the old grid first.
    func resizeSessionToFitView(coalesce: Bool = true) {
        // Nothing reaches the child before the window is sized: a layout of the
        // view at its placeholder size would strand blank rows under the
        // prompt. The session is born at the target size, so nothing is lost.
        guard didSizeWindow, session != nil, let terminalRenderer, view.window != nil
        else { return }
        let grid = gridSize(fitting: view.bounds.size)
        let pixels = pixelSize(
            columns: Int(grid.columns), rows: Int(grid.rows), metrics: terminalRenderer.metrics)
        let size = TerminalSize(
            rows: grid.rows, columns: grid.columns, pixelWidth: pixels.width, pixelHeight: pixels.height)
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
                device: device, font: fontStyle.font(ofSize: fontSize), scale: scale,
                options: fontStyle.options)
        } catch let error where error is GlyphAtlasError || error is Metal4BackendError {
            // The GPU, not the face: the default font would fail the same way,
            // and resetting to it lost the pane's size and family for good.
            throw error
        } catch {
            fontSize = Self.defaultFontSize
            fontStyle = FontStyle()
            renderer = try TerminalRenderer(
                device: device, font: fontStyle.font(ofSize: fontSize), scale: scale,
                options: fontStyle.options)
        }
        // A finished decode schedules a frame; otherwise it waits for unrelated
        // output.
        renderer.kittyImageRenderer.onImagesReady = { [weak self] in
            DispatchQueue.main.async { self?.invalidateDisplay() }
        }
        // Glyphs a frame's shaping budget left for later.
        renderer.onGlyphsDeferred = { [weak self] in
            DispatchQueue.main.async { self?.invalidateDisplay() }
        }
        return renderer
    }

    /// With `isOperable` false every geometry and render entry short-circuits.
    /// `canReconnect` adds Reconnect, described as a new connection.
    private func presentFailure(
        title: String, detail: String, canRetry: Bool, canReconnect: Bool = false,
        takesFocus: Bool = true
    ) {
        failureView?.removeFromSuperview()
        let failure = PaneFailureView(
            title: title, detail: detail, canRetry: canRetry, canReconnect: canReconnect)
        failure.onRetry = { [weak self] in self?.rebuildPane(strictRespawn: false) }
        // A runtime failure may leave a live child. This explicit recovery
        // button, with its new-session warning, can replace it too.
        failure.onReconnect = { [weak self] in self?.rebuildPane(strictRespawn: true) }
        failure.onOpenSettings = { SettingsWindowController.shared.show(nil) }
        failure.present(in: view, takesFocus: takesFocus)
        failureView = failure
    }


    /// Behind Try Again (the ladder) and Reconnect (the exact command).
    func rebuildPane(strictRespawn: Bool) {
        terminalView?.stopRendering()
        readerDemotion?.cancel()
        readerDemotion = nil
        frameLoop.detach()
        session?.stop()
        session = nil
        removeBootstrapFolder()
        terminalRenderer = nil
        failureView?.removeFromSuperview()
        failureView = nil
        sessionEnd.dismiss()
        terminalView?.removeFromSuperview()
        terminalView = nil
        // A new session: nothing of the old one's viewport, selection or
        // overlays may point into it.
        focus.removeViews()
        pointer.reset()
        selection = nil
        scrollOffset = 0
        setUpPane(strictRespawn: strictRespawn)
        guard isOperable, let terminalView else { return }
        // The window settled long ago; this pane needs a real winsize now.
        didSizeWindow = true
        // A new view and renderer start composited; a full-screen window's
        // direct presentation (#285) applies to them as to the old ones.
        splitController?.updateDirectPresentation()
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
}
