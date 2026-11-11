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

// The pane controller is one file by design (`docs/DESIGN.md` §4.1: no
// `TerminalPaneViewController+X.swift`; new behaviour goes to a collaborator), so its
// length is judged there, not by the generic file-length limit. Its type
// and function lengths are still checked.
// swiftlint:disable file_length

import Cocoa
import CortaPOSIX
import CortaTerminal
import Metal

/// One pane: a `TerminalSession` and the renderer and view that draw it.
/// Knows no sibling panes beyond `splitController` (D07). The pane keeps
/// the session, the view, the renderer, sizing, teardown and the wiring
/// between them; each other concern is a collaborator it composes
/// (`docs/DESIGN.md` §4.1), and new behaviour is added as one.
class TerminalPaneViewController: NSViewController, PaneSearchHost, PaneRemoteHost, PaneCommandsHost,
    PaneFocusHost, PanePointerHost, PaneShellIntegrationHost, PaneAppearanceHost,
    PaneSessionEndHost, NSMenuItemValidation
{
    // Not `private`: extensions reach these and cannot add storage.
    var terminalView: TerminalView!
    var terminalRenderer: TerminalRenderer!
    var session: TerminalSession!
    lazy var agents = PaneAgents(host: self)
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
        if visible {
            readerHiddenSince = nil
        } else if readerHiddenSince == nil {
            readerHiddenSince = now
        }
        let priority = ReaderPriorityPolicy.priority(
            visible: visible, selected: true,
            hiddenSince: readerHiddenSince, lastInput: readerLastInput, now: now)
        session.setReaderPriority(priority)
        if priority == .interactive, !visible {
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
    var fontSize: CGFloat = TerminalPaneViewController.defaultFontSize
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
    /// That directory was checked a moment ago, for this first spawn alone;
    /// a retry later has no such word for it.
    var inheritedDirectoryChecked = false
    var initialGridSize: TerminalSize?

    /// Applied once at spawn; set before the view loads.
    var preset: Preset?
    /// What a restored arrangement said about this pane's remote side
    /// (`#519`). Read once, at the first spawn: a connect-sheet target shows
    /// the ended-session panel instead of spawning, and a hand-typed launcher
    /// gives a local shell that says it was remote. Set before the view loads.
    var restoredRemote: PaneRemoteRestore?

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
    /// A frame has drawn the child's output: a new tab can show this pane
    /// without an empty canvas (`TabContainerViewController.show(_:holding:)`).
    private(set) var drewFirstOutput = false
    /// Runs once, as the first frame with output is prepared.
    var onFirstOutputFrame: (() -> Void)?
    var selection: TerminalSelection?
    /// Non-nil exactly when `isOperable` is false.
    var failureView: PaneFailureView?
    /// Shown from the moment this pane's session ends until a new one
    /// starts or the pane closes (`SessionEnded`).
    private(set) lazy var sessionEnd = PaneSessionEnd(host: self)
    var sessionEndedPanel: PaneStatusOverlay? { sessionEnd.overlay }
    /// A fallback shell or directory, reported once the toast can be seen.
    private(set) var pendingSessionNotice: String?
    /// The window is sized (`SplitViewController.prepareWindow`); until then a
    /// layout runs at a placeholder size and must not reach the child
    /// (`resizeSessionToFitView`).
    var didSizeWindow = false
    private var resizeDebouncer: ResizeDebouncer!
    /// The size the debouncer last handed the session, to tell a reflow.
    private var lastCommittedSize: TerminalSize?

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
    private(set) lazy var paneHeader = PaneHeader(pane: self)

    /// The child sees the final size now, not after the debounce.
    func endLiveResize() { resizeDebouncer?.flush() }

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
            return TerminalLayout.titlebarHeight + TerminalLayout.insets.top + PaneHeader.height
        }
        return TerminalLayout.insets.top + chromeOverlap + PaneHeader.height
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
    /// The focused pane of the tab in front: the one whose own UI may take
    /// the keyboard. A background tab's focused pane must not (D30).
    var holdsWindowFocus: Bool { isFocusedPane && splitController?.tab?.isSelected ?? true }

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
            width: max(230, CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth),
            height: CGFloat(minimumRows) * metrics.cellHeight + TerminalLayout.insetHeight + PaneHeader.height)
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
            width: CGFloat(grid.columns) * metrics.cellWidth + TerminalLayout.insetWidth + 2 * PaneSurfaceView.margin,
            height: CGFloat(grid.rows) * metrics.cellHeight + TerminalLayout.insetHeight
                + windowChrome + PaneHeader.height + 2 * PaneSurfaceView.margin)
    }

    override func loadView() { view = PaneSurfaceView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpPane()
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
        terminalView?.discardComposition()
        focus.stop()
        inputSourceIndicator.stop()
        windowTitle.stop()
        search.close()
        commands.stop()
        agents.reset()
        taskNotifier.cancel()
        remote.cancelPendingOpens()
        remote.stopWatchingConnection()
        appearance.stop()
        // A resize still waiting out the drag debounce would reach the
        // stopping session, and its output callback a pane that is gone;
        // detaching retires the generation every late callback checks.
        resizeDebouncer?.cancel()
        frameLoop.detach()
        terminalView?.stopRendering()
        session?.stop()
        // The pane is gone; its history need not live on with the reader
        // while the child is given its grace period (`SECURITY.md` §4.4).
        session?.releaseContents()
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
        paneHeader.place()
        search.placeClearOfContent()
    }

    /// ⌘A: `NSResponder` declares it, so the pane overrides rather than
    /// forwards.
    override func selectAll(_ sender: Any?) { pointer.selectAll(sender) }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let notice = pendingSessionNotice {
            pendingSessionNotice = nil
            terminalView?.showToast(notice, kind: .warning)
        }
    }

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
        guard didSizeWindow, session != nil, let terminalRenderer, view.window != nil,
            splitController?.splitTransition.isRunning != true,
            splitController?.isRearrangingPanes != true
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
            if view.inLiveResize { windowTitle.noteTransientSizeChange() } else { windowTitle.endTransientSize() }
            windowTitle.apply()
        }
    }
}

// MARK: - Sizes in cells

extension TerminalPaneViewController {
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
}

// MARK: - Setting up

extension TerminalPaneViewController {
    /// Builds a pane or retries a failed setup. Reconnect must reuse the exact
    /// recorded command; ordinary startup may fall back to a working shell.
    /// A rebuild keeps the pane's grid and font size: the new child is born
    /// at the size it is shown at, and the window does not move.
    private func setUpPane(strictRespawn: Bool = false, keeping grid: TerminalSize? = nil) {
        let restore = RestoredRemoteAction.forRestore(restoredRemote, strictRespawn: strictRespawn)
        restoredRemote = nil
        if grid == nil || !isFontSizeZoomed {
            fontSize = Configuration.fontSizeRange.clamped(ConfigurationStore.shared.configuration.fontSize)
        }
        if case .connectionPanel(let target) = restore {
            // Nothing is spawned for a restored connection: a launch may not
            // connect on its own, nor put a local shell where a remote
            // session was (`#519`). Reconnect leaves this state; New Session
            // starts a local shell through `startLocalSession`.
            sessionEnd.presentRestoredConnection(hostName: target.displayName)
            return
        }
        let configuration = ConfigurationStore.shared.configuration
        fontStyle = FontStyle(configuration)
        guard prepareRenderer() else { return }
        let initialSize = initialTerminalSize(keeping: grid)
        guard let started = startSession(strictRespawn: strictRespawn, size: initialSize, configuration: configuration)
        else { return }
        adopt(started, size: initialSize)
        if restore == .spawnWithRemoteNote {
            // Said once, when this first output can be seen: this shell is
            // local, though the pane's last session was not (`#519`).
            pendingSessionNotice = L10n.text("restore.remoteNotResumed")
        }
        // Before the reader starts, so the shell's first output is measured
        // the way the configuration says.
        session.ambiguousWidthIsWide = configuration.ambiguousWidth == .wide
        installPaneViews(sizingView: grid == nil)
        installSessionCallbacks()
        installTerminalCallbacks(on: terminalView)
        // The PTY reader must not run until all callbacks and views are ready.
        session.start()
        remote.watchForEstablishedConnection()
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
    private func initialTerminalSize(keeping grid: TerminalSize? = nil) -> TerminalSize {
        let size = grid ?? initialGridSize ?? configuredGridSize
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
            defer { inheritedDirectoryChecked = false }
            return try PaneSpawn.start(
                size: size, directory: inheritedWorkingDirectory, directoryChecked: inheritedDirectoryChecked,
                scrollbackLimit: configuration.scrollbackLines,
                commandHistoryLimit: configuration.commandHistoryLimit, preset: preset,
                directoryCompletion: configuration.directoryCompletion,
                historySuggestions: configuration.historySuggestions)
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
        session.updateTheme(colors: variant.dynamicColors, isDark: AppearanceController.shared.isDark)
        session.indexedPalette = variant.indexedPaletteDefaults
        pendingSessionNotice = started.notice
        lastRequestedSize = size
    }

    /// `sizingView` false on a rebuild: the view already has its place in
    /// the window, and sizing it to the configured grid moved the pane.
    private func installPaneViews(sizingView: Bool = true) {
        let contentSize = sizingView ? initialWindowContentSize : view.bounds.size
        if sizingView { self.view.setFrameSize(contentSize) }

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
        self.view.addSubview(paneHeader)
    }

    private func installSessionCallbacks() {
        lastCommittedSize = nil
        resizeDebouncer = ResizeDebouncer { [weak self] size in
            guard let self, let session = self.session else { return }
            let columnsChanged = self.lastCommittedSize.map { $0.columns != size.columns } ?? false
            self.lastCommittedSize = size
            session.resize(to: size)
            // A reflow renumbers rows; matches found before it would be
            // drawn over the wrong text until the next paced sweep.
            if columnsChanged { self.search.invalidateResults() }
        }
        // Each is idempotent: a retry's second setup observes nothing twice.
        focus.observeWindows()
        appearance.observe()
        let generation = frameLoop.attach(session: session, renderer: terminalRenderer)
        taskNotifier.cancelProgramNotifications()
        agents.reset()
        let wake = frameLoop.outputWake
        frameLoop.onOutputSignal = { [weak self] in
            guard let self else { return }
            self.agents.readOutput()
            if !self.agents.visible, self.session?.takeBell() == true { self.handleBell() }
            self.windowTitle.noteOutput()
            // A hidden tab draws no frame, and a long task's end must not
            // wait for it to be shown.
            self.noteCommandBoundaries()
            if self.view.isHiddenOrHasHiddenAncestor { self.frameLoop.runEffectsWhileHidden() }
        }
        taskNotifier.tabInFront = { [weak self] in self?.splitController?.tab?.isSelected ?? true }
        taskNotifier.programCanDeliver = { [weak self] notice in
            guard let self, !self.didTeardown, self.frameLoop.isCurrent(generation) else { return false }
            switch notice.occasion {
            case .always: return true
            case .invisible: return !self.agents.visible
            case .unfocused:
                return !(NSApp.isActive && self.view.window?.isKeyWindow == true && self.holdsWindowFocus)
            }
        }
        taskNotifier.sessionGeneration = generation
        taskNotifier.lastOutputUptimeNanoseconds = { wake.lastOutputUptimeNanoseconds }
        taskNotifier.title = { [weak self] in self?.windowTitle.notificationTitle ?? "Corta" }
        session.onChildExit = { [weak self] childExit in
            Task(priority: .userInitiated) { @MainActor in
                self?.noteChildExit(childExit, generation: generation)
            }
        }
        session.onIOFailure = { [weak self] failure in
            Task(priority: .userInitiated) { @MainActor in
                self?.noteIOFailure(failure, generation: generation)
            }
        }
    }

    /// The session's reads or writes failed: rendering stops and the
    /// failure panel offers Retry — or Reconnect, for a remote launcher.
    private func noteIOFailure(_ failure: TerminalSession.IOFailure, generation: Int) {
        guard !didTeardown, frameLoop.isCurrent(generation) else { return }
        let reconnect = remote.reconnectCommand.map {
            PaneRemoteState.isRemoteLauncher(executable: $0.executable)
        } ?? false
        frameLoop.suspendRendering()
        terminalView?.stopRendering()
        let title = reconnect
            ? remote.connectionHost.map { L10n.format("failure.title.connectionLost.host", $0) }
                ?? L10n.text("failure.title.connectionLost")
            : L10n.text("failure.title.runtimeSession")
        // The last output stays readable behind it; the raw
        // reason is the detail, not the sentence.
        presentFailure(title: title,
            detail: L10n.text("failure.runtimeSession.body"),
            canRetry: !reconnect, canReconnect: reconnect,
            details: failure.description,
            note: L10n.text(reconnect ? "session.ended.connection.note" : "failure.retryHint"),
            showsSettings: false, backdrop: .dim,
            symbol: reconnect ? "bolt.horizontal.circle" : "exclamationmark.triangle",
            tint: reconnect ? .systemRed : .systemOrange,
            takesFocus: holdsWindowFocus)
    }

    private func installTerminalCallbacks(on view: TerminalView) {
        frameLoop.install(on: view)
        pointer.install(on: view)
        installInputSourceIndicator(on: view)
        view.onCompletionKey = { [weak self] event in self?.shell.handleDirectoryCompletionKey(event) ?? false }
        view.onEndedSessionKey = { [weak self] event in self?.sessionEnd.focusActions(event) ?? false }
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
        view.cellSize = CGSize(
            width: terminalRenderer.pointMetrics.cellWidth, height: terminalRenderer.pointMetrics.cellHeight)
        view.preeditFontProvider = { [weak self] in
            guard let self else {
                return NSFont.monospacedSystemFont(
                    ofSize: TerminalPaneViewController.defaultFontSize, weight: TerminalFont.systemWeight)
            }
            return fontStyle.font(ofSize: fontSize) as NSFont
        }
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.inputSourceIndicator.refreshSource()
            self.splitController?.noteFocus(self)
        }
    }
}

// MARK: - Frames and output

extension TerminalPaneViewController {
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
                detail: L10n.text("failure.runtimeRenderer.body"),
                canRetry: !reconnect, canReconnect: reconnect,
                details: "\(error)",
                note: L10n.text(reconnect ? "session.ended.connection.note" : "failure.retryHint"),
                showsSettings: false, takesFocus: self.holdsWindowFocus)
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
        title.tab = { [weak self] in self?.splitController?.tab }
        title.gridSize = { [weak self] in self?.lastRequestedSize }
        title.canApplyDeferred = { [weak self] in
            guard let self else { return false }
            return !didTeardown && isFocusedPane
        }
        title.refreshBackgroundPresentation = { [weak self] in
            guard let self, !self.didTeardown else { return }
            self.paneHeader.refresh()
            (self.view.window?.windowController as? TerminalWindowController)?.refreshTabTitle()
        }
        return title
    }

    /// The output-batch stage: what a batch changes beyond the grid. Title,
    /// directory and process all arrive as output, so this keeps the window
    /// and tab title current without a timer; an unfocused pane's applies on
    /// focus.
    private func noteOutputBatch() {
        guard session != nil else { return }
        if !drewFirstOutput {
            drewFirstOutput = true
            let first = onFirstOutputFrame
            onFirstOutputFrame = nil
            first?()
        }
        paneHeader.refresh()
        pointer.noteGridChanged()
        if isFocusedPane {
            windowTitle.apply(fromOutput: true)
        } else {
            // A background pane may change the program behind a stacked tab
            // icon without taking keyboard focus. TabIcon caches the artwork.
            (view.window?.windowController as? TerminalWindowController)?.refreshTabStripSoon()
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
        noteCommandBoundaries()
    }

    /// What the shell reported of its commands since the last look; from a
    /// frame or, in a tab that draws none, from the output signal.
    private func noteCommandBoundaries() {
        guard let session else { return }
        // One lock for what used to take four.
        let boundary = session.takeCommandBoundaryState()
        shell.noteCommandState(statusRevision: boundary.statusRevision, isCommandRunning: boundary.isCommandRunning)
        let finished = boundary.finishedExitStatus
        // The prompt's return is the moment the program left: the title
        // names the shell again now, not an interval later.
        if finished != nil, isFocusedPane {
            windowTitle.invalidateProcessFacts()
            windowTitle.apply()
        }
        if boundary.hasShellIntegration {
            taskNotifier.noteCommandRunning(
                boundary.isCommandRunning, exitStatus: finished, commandID: boundary.lastCompletedID,
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
            let frame = PaneInputSourceIndicator.FrameState(
                grid: grid, hasIntegration: inputMetadata.hasIntegration,
                promptRow: inputMetadata.promptRow,
                focused: focus.hasUserFocus && view.window?.firstResponder === terminalView,
                scrollOffset: scrollOffset,
                cellSize: CGSize(width: metrics.cellWidth, height: metrics.cellHeight),
                topInset: topInset, compositionRect: terminalView.inputCompositionRect,
                blockedRects: configuration.inputSourceIndicatorPosition == .toolbar ? [] :
                    terminalView.shellOverlay.occupiedRects + (search.bar.map { [$0.frame] } ?? []))
            inputSourceIndicator.update(frame, configuration: configuration, canvas: canvas)
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
                && sessionEndedPanel == nil,
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
        agents.bell()
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
        agents.exited(exit) // Reads the final output itself first.
        // A dead child produces no output to rebuild the title; the `Remote: host`
        // badge would outlive its connection.
        windowTitle.invalidateProcessFacts()
        windowTitle.apply()
        // A remote launcher: the connection ended, and the way back is a new one.
        let isConnection =
            launchedCommand.map { PaneRemoteState.isRemoteLauncher(executable: $0.executable) }
            ?? false
        let program = launchedCommand.map { ($0.executable as NSString).lastPathComponent }
            ?? L10n.text("session.ended.local.unnamed")
        sessionEnd.present(
            exit, isConnection: isConnection, remoteHost: isConnection ? remote.connectionHost : nil,
            program: program)
    }

    func closeEndedPane() {
        if let split = splitController, split.hasMultiplePanes {
            split.closePane(self)
        } else {
            if let split = splitController { split.performCloseTab(nil) } else { view.window?.performClose(nil) }
        }
    }

    /// For local changes that produce no output.
    func invalidateDisplay() {
        focus.noteCursorActivity()
        updateReaderPriority()
        frameLoop.invalidate()
    }

    /// The header too: its light or dark follows the canvas, and its title
    /// the focus.
    func refreshFocusAppearance() {
        focus.applyAppearance()
        paneHeader.refresh()
    }

    /// The grid now, or nil for a failed pane.
    func snapshot() -> Grid? {
        session?.snapshot()
    }

    func liveTotalPushed() -> Int? { session?.scrollbackTotalPushed }

    func selectedTextForFind() async -> String? {
        guard let session, let (grid, range) = commands.selectionSnapshot() else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            Selection.firstNonemptyLine(of: range, in: grid)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return !Task.isCancelled && self.session === session && !didTeardown ? result : nil
    }

    func setFontSize(_ newSize: CGFloat, settle: Bool = true) {
        appearance.setFontSize(newSize, settle: settle)
    }

    func settleFontChange() { appearance.settleFontChange() }

    /// What copy, export and open-reference act on (`PaneShellIntegration`).
    var effectiveCommand: CommandRecord? { shell.effectiveCommand }
}

// MARK: - Failure paths

extension TerminalPaneViewController {
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
        // Set before the pane can draw, including after a renderer retry.
        // SplitViewController may later add the full-screen option.
        renderer.presentsByCopy = DirectFullScreen.presentsByCopy([])
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
        details: String? = nil, note: String? = nil, showsSettings: Bool = true,
        backdrop: PaneStatusOverlay.Backdrop = .opaque,
        symbol: String = "exclamationmark.triangle", tint: NSColor = .systemOrange,
        takesFocus: Bool = true
    ) {
        failureView?.removeFromSuperview()
        let failure = PaneFailureView(
            title: title, detail: detail, canRetry: canRetry, canReconnect: canReconnect,
            details: details, note: note, showsSettings: showsSettings, backdrop: backdrop,
            symbol: symbol, tint: tint)
        failure.onRetry = { [weak self] in self?.rebuildPane(strictRespawn: false) }
        // A runtime failure may leave a live child. This explicit recovery
        // button, with its new-session warning, can replace it too.
        failure.onReconnect = { [weak self] in self?.rebuildPane(strictRespawn: true) }
        failure.onOpenSettings = { SettingsWindowController.shared.show(nil) }
        failure.present(in: view, takesFocus: takesFocus)
        failureView = failure
    }

    /// A direct remote launcher owns the PTY itself, so it has no separate
    /// foreground job even when closing it would end a live connection.
    var hasSessionRequiringCloseConfirmation: Bool {
        guard let session, !session.isStopped, session.pty.exitStatus == nil else { return false }
        return session.hasForegroundJob || remote.childIsLiveLauncher
    }

    /// Connect replaces this pane's session with the chosen destination.
    /// Clear the old spawn record so strict startup uses the new preset.
    func connect(using preset: Preset) {
        guard !didTeardown else { return }
        remote.cancelPendingOpens()
        remote.stopWatchingConnection()
        search.close()
        self.preset = preset
        launchedCommand = nil
        rebuildPane(strictRespawn: true, showsReconnectNotice: false)
    }

    /// Behind Try Again (the ladder) and Reconnect (the exact command).
    func rebuildPane(strictRespawn: Bool) {
        rebuildPane(strictRespawn: strictRespawn, showsReconnectNotice: true)
    }

    private func rebuildPane(strictRespawn: Bool, showsReconnectNotice: Bool) {
        // The grid it is shown at, while a session still says so; a pane
        // that never built starts from the configured one.
        // A restored connection (#519) has no session but sits in a sized
        // window: it keeps the grid its split gave it, not the configured one.
        let grid = didSizeWindow ? (session != nil ? lastRequestedSize : initialGridSize) : nil
        // Input on its way to the old session has nowhere to land now, and
        // must not land in the new one.
        commands.fileDropRequest?.cancel()
        commands.fileDropRequest = nil
        commands.cancelPasteScan()
        terminalView?.discardComposition()
        terminalView?.stopRendering()
        readerDemotion?.cancel()
        readerDemotion = nil
        // Its matches and any sweep in flight read the old session's grid.
        search.close()
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
        setUpPane(strictRespawn: strictRespawn, keeping: grid)
        guard isOperable, let terminalView else { return }
        // The window settled long ago; this pane needs a real winsize now.
        didSizeWindow = true
        // A new view and renderer start composited; a full-screen window's
        // direct presentation (#285) applies to them as to the old ones.
        splitController?.updateDirectPresentation()
        view.window?.makeFirstResponder(terminalView)
        resizeSessionToFitView(coalesce: false)
        invalidateDisplay()
        if let notice = pendingSessionNotice {
            // `viewDidAppear` shows a first spawn's fallback; a rebuild's
            // view appears without one.
            pendingSessionNotice = nil
            terminalView.showToast(notice, kind: .warning)
        } else if strictRespawn && showsReconnectNotice {
            // Every time: a new connection; the old scrollback is gone.
            terminalView.showToast(remote.reconnectNotice)
        }
    }
}

// MARK: - Restoring a remote side

extension TerminalPaneViewController {
    /// What a save records of this pane's remote side (`#519`): the connect
    /// sheet's own target, or the fact of a hand-typed launcher. A configured
    /// preset is run again on restore, so it needs no note; a reported host is
    /// child output and is never recorded (`SECURITY.md` §2).
    var restorableRemote: PaneRemoteRestore? {
        if let target = preset?.connectTarget { return .target(target.key) }
        guard preset == nil else { return nil }
        switch remote.state {
        case .remote, .remoteUnknown: return .launcher
        case .local, .connected, .unknown: return nil
        }
    }

    /// What takes the keyboard when this pane is focused: its terminal, or —
    /// for a restored connection that never built one (`#519`) — the primary
    /// action of its panel, as a failure's card does.
    var keyboardTarget: NSResponder? {
        terminalView ?? sessionEndedPanel?.panel.buttons.last
    }

    /// A restored connection's panel: a local shell in the saved directory,
    /// with the saved ssh preset dropped so New Session cannot run it.
    /// Reconnect is the panel's other action, and reuses that preset.
    func startLocalSession() {
        guard !didTeardown else { return }
        remote.cancelPendingOpens()
        remote.stopWatchingConnection()
        search.close()
        preset = nil
        launchedCommand = nil
        restoredRemote = nil
        rebuildPane(strictRespawn: false, showsReconnectNotice: false)
    }
}
