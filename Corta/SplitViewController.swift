import Cocoa
import CortaTerminal

/// M5 — the window's content controller: owns the split layout tree
/// (`SplitTree`), the panes (one `ViewController` — one `TerminalSession` —
/// per leaf, `DESIGN.md` §2.4) and the focus that routes input to one of
/// them (M5.2). Window-level setup the single-pane `ViewController` used
/// to do itself (chrome, content size, first responder) lives here now:
/// with N panes there is still exactly one window.
///
/// Composition, not new mechanism: a pane renders its session into its own
/// drawable in one pass exactly as before (M5.3), and a pane view resizing
/// — divider drag or window resize — flows through the pane's existing
/// `resizeSessionToFitView` path to its own PTY (M5.4).
final class SplitViewController: NSViewController {
    private var tree: SplitTree!
    /// The pane keyboard and mouse input belong to (M5.2). Set by
    /// `noteFocus` from `TerminalView.becomeFirstResponder`, so every route
    /// to focus — click, ⌘⌥ arrows, a split, a close — funnels through one
    /// place.
    /// Settable from `SplitViewController+Restore`, which walks a saved
    /// layout by focusing each pane in turn and splitting it — the same path
    /// ⌘D takes, rather than a second tree builder.
    var focusedPane: ViewController?
    /// Window setup ran (`viewWillAppear`). Panes created by a split later
    /// take `didSizeWindow` from this.
    private var didSetUpWindow = false
    /// True once the content view has laid out filling its window's frame —
    /// the transient-layout gate of `resizeSessionToFitView`, moved one
    /// level up. A pane in a split tree legitimately does *not* fill the
    /// window, so the pane cannot run the check against its own bounds
    /// anymore; the content view always fills it, split or not, so the
    /// check keeps its exact meaning here. Set in `viewWillLayout` — before
    /// the subviews' layout in the same pass — so panes see it in the pass
    /// that settles.
    private(set) var layoutSettled = false
    /// The one-time frame correction ran (or the window is a tab and takes
    /// the group's frame). Panes deliver no winsize until this and
    /// `layoutSettled` both hold — see `resizeSessionToFitView`.
    private var didCorrectWindowSize = false
    /// Both startup gates: the window has laid out at full height and its
    /// frame has been corrected to fit the initial grid exactly.
    var sizeSettled: Bool { layoutSettled && didCorrectWindowSize }
    /// The chrome height seen at the last layout, for absorbing tab-bar
    /// appearance into the frame rather than the content area.
    private var lastChromeHeight: CGFloat?

    var panes: [ViewController] { children.compactMap { $0 as? ViewController } }
    var hasMultiplePanes: Bool { tree?.leafCount ?? 1 > 1 }

    /// The layout this window is being restored into (M7.4), set by
    /// `AppDelegate` before the view loads. The root pane needs its working
    /// directory at spawn time, which is why this has to be here rather than
    /// applied afterwards.
    var pendingRestore: WindowState?

    /// U16 — the preset this window's first pane should spawn from. Set
    /// before the view loads, for the same reason `pendingRestore` is: the
    /// root pane needs its shell, directory and environment at spawn time,
    /// and a preset applied afterwards would relabel a child that had already
    /// started somewhere else.
    var pendingPreset: Preset?

    override func viewDidLoad() {
        super.viewDidLoad()
        let pane = makePane(
            workingDirectory: pendingRestore?.layout.firstDirectory, initialGridSize: nil,
            preset: pendingPreset)
        focusedPane = pane
        tree = SplitTree(root: pane.view)
        installRoot()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard !didSetUpWindow, let window = view.window, let pane = focusedPane else { return }
        didSetUpWindow = true
        pane.didSizeWindow = true
        // A pane that failed to build (`PaneFailureView`) has no atlas to
        // measure, so the window falls back to the storyboard's size rather
        // than to a trap.
        guard let metrics = pane.terminalRenderer?.pointMetrics else {
            didSetUpWindow = false
            return
        }
        window.title = "Corta"
        // Tabs (M4.7) are native window tabbing: `.automatic` here, and File >
        // New Tab joins the key window's tab group. The tab label follows
        // `window.title`, which the OSC 0/2 title update keeps current.
        window.tabbingMode = .automatic
        // Chrome follows the system appearance — dark bar in dark mode,
        // light in light mode; the terminal surface itself stays dark.
        window.appearance = nil
        // Content runs the full height under a visible titlebar
        // (`.fullSizeContentView`): the bar keeps its material, title,
        // traffic lights and double-click/drag behaviour, and the grid's
        // top inset is measured from it at runtime (`windowChrome`). This
        // is `viewWillAppear`, not `viewDidAppear`, for a reason: the style
        // mask must be final before the window's first layout — see
        // `resizeSessionToFitView` in `ViewController` for what a transient
        // size strands in the child.
        //
        // Inserting the flag re-derives the frame from the content size, so
        // the window silently loses a chrome height at that moment. The
        // frame is captured here and restored below for the one caller that
        // does not overwrite it anyway.
        let frameBeforeStyleChange = window.frame
        window.styleMask.insert(.fullSizeContentView)
        // A terminal window has nothing to restore: its content is a live
        // child process, not a document. Left restorable, AppKit re-applied
        // a saved frame *after* the deliberate sizing below — the window
        // opened at a stale size, and the stale size was whatever the tab
        // bug had shrunk it to last time, so the two compounded across
        // launches.
        window.isRestorable = false
        // The Metal layer clears to a translucent colour; the window has to
        // stop painting its own opaque background for that to show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Dragging snaps to whole cells, so a resize never leaves a partial
        // row or column.
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        updateWindowMinSize()
        // On this OS, once `.fullSizeContentView` is in the mask,
        // `setContentSize` sizes the *frame* (the content view spans the
        // frame) — and it still miscalculates the chrome by a full titlebar
        // height on the first call. The size is therefore corrected once in
        // `viewDidAppear`, after AppKit's final adjustment; the
        // session is born at the target grid size and nothing is delivered
        // before then (`sizeSettled` gate), so no transient winsize reaches
        // the child (D.1).
        //
        // A window joining a tab group (File > New Tab) takes the group's
        // frame — sizing it here would resize the shared window, which is
        // the visible "the whole window moves when a tab opens" jump.
        if window.tabbedWindows == nil {
            window.setContentSize(pane.initialWindowContentSize)
        } else if window.frame != frameBeforeStyleChange {
            // The chrome height the style-mask insert took off the frame
            // (see above). A standalone window's `setContentSize` overwrites
            // the frame and hides it; a tab keeps the group's frame, so it
            // kept the loss — which is why every ⌘T shrank the shared window
            // by a chrome (32pt, then 68pt once the tab bar was up) until it
            // bottomed out at the minimum size.
            window.setFrame(frameBeforeStyleChange, display: false)
        }
        // Nothing else claims first responder, and without one the view
        // hierarchy — the terminal view, the controllers — is not in the
        // responder chain at all: keyDown never fires and menu actions
        // targeting First Responder (⌘V, ⌘=, ⌘D) dispatch from the window
        // down. The terminal view is where keys belong.
        window.makeFirstResponder(pane.terminalView)
        // Paint one frame before the window is on screen: the window's
        // background is transparent until the Metal layer has presented
        // once, so without this every new window and every new tab flashes
        // the desktop for a frame or two.
        view.layoutSubtreeIfNeeded()
        pane.terminalView?.drawNow()

        // The splits, last: they need the window's final frame to halve, and
        // the frame is only final once the sizing above has run.
        if let restore = pendingRestore {
            pendingRestore = nil
            // The saved frame is authoritative; the default-grid correction
            // must not overwrite it after the window appears.
            didCorrectWindowSize = true
            // Clamped to a display that exists now — see `Frame.onScreen`.
            if window.tabbedWindows == nil {
                window.setFrame(restore.frame.onScreen(), display: false)
            }
            view.layoutSubtreeIfNeeded()
            self.restore(layout: restore.layout)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // AppKit applies `.fullSizeContentView`'s final frame adjustment after
        // the last pre-display layout. Correcting in `viewWillLayout` saw the
        // still-correct frame, marked the work done, and then AppKit removed
        // one titlebar height — turning a configured 120×30 into 120×27.
        // At this point that adjustment is complete, while the session is
        // still protected by the `sizeSettled` gate.
        correctInitialWindowSize()
        view.layoutSubtreeIfNeeded()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        // See `layoutSettled`. `.fullSizeContentView` effective means the
        // content view spans the window's whole frame; anything else is the
        // pre-style-mask transient (observed: 522pt content against a 554pt
        // frame on the first layout pass).
        if !layoutSettled, let window = view.window,
            abs(view.bounds.height - window.frame.height) < 1
        {
            layoutSettled = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        absorbChromeChange()
    }

    /// A tab bar appearing or disappearing changes the chrome height without
    /// any user resize; AppKit answers by shrinking the content area, which
    /// visibly pushes the grid down and costs every pane the bar's worth of
    /// rows. Absorb the delta into the frame instead: the window grows
    /// downward (the titlebar stays put) and every pane keeps its row count.
    ///
    /// Called from `viewDidLayout` for the changes this window sees, and
    /// from `AppDelegate.newTab` for the one it cannot: the window whose
    /// chrome grows when a tab joins is the window the new tab covers, so it
    /// never lays out again on its own.
    func absorbChromeChange() {
        // `isVisible` and `sizeSettled` together mean setup is over. Before
        // that `contentLayoutRect` is still the pre-`setContentSize` content
        // area (observed once at an origin of -302), and the chrome measured
        // off it is nonsense that absorbs into a visible startup jump.
        guard let window = view.window, didSetUpWindow, sizeSettled, window.isVisible
        else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let last = lastChromeHeight
        // Recorded before the resize, not after: `setFrame` lays out
        // reentrantly, and the nested call would otherwise read the stale
        // value and absorb the same delta a second time.
        lastChromeHeight = chrome
        guard let last, chrome != last, !window.inLiveResize,
            !window.styleMask.contains(.fullScreen)
        else { return }
        var frame = window.frame
        frame.origin.y -= chrome - last
        frame.size.height += chrome - last
        window.setFrame(frame, display: true)
    }

    /// The one-time correction for `setContentSize` mismeasuring the chrome
    /// on the first call (see `viewWillAppear`). Sized by frame because that
    /// is what `setContentSize` now drives; the pane area spans the frame
    /// with `.fullSizeContentView`.
    private func correctInitialWindowSize() {
        guard !didCorrectWindowSize, let window = view.window, let pane = focusedPane
        else { return }
        // A tab takes the group's frame; nothing to correct.
        guard window.tabbedWindows == nil else {
            didCorrectWindowSize = true
            return
        }
        let target = pane.initialWindowContentSize
        guard abs(window.frame.height - target.height) > 1
            || abs(window.frame.width - target.width) > 1
        else {
            didCorrectWindowSize = true
            return
        }
        didCorrectWindowSize = true
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: true)
    }

    // MARK: - Panes

    /// Creates a pane and its session. The view is force-loaded here so the
    /// session spawns with the target grid size and working directory — the
    /// shell's first output is then laid out against the right width
    /// instead of the storyboard default and reflowed after.
    private func makePane(
        workingDirectory: String?, initialGridSize: TerminalSize?, preset: Preset? = nil
    ) -> ViewController {
        let pane = ViewController()
        // U16 — set before `pane.view` loads: the preset supplies the shell,
        // the directory and the environment at spawn time.
        pane.preset = preset
        // M5.5: a split pane opens where the focused pane is, via OSC 7
        // (M2.8); nil (no report yet) falls back to the home directory.
        // `TerminalSession.workingDirectory` is already host-filtered, so a
        // pane ssh'd into a remote machine never hands its remote path to a
        // local spawn.
        pane.inheritedWorkingDirectory = workingDirectory
        pane.initialGridSize = initialGridSize
        pane.didSizeWindow = didSetUpWindow
        addChild(pane)
        _ = pane.view
        return pane
    }

    private func pane(forLeaf leaf: NSView) -> ViewController? {
        panes.first { $0.view === leaf }
    }

    /// The window's content view has exactly one subview: the tree's root.
    /// The root changes identity when the first split replaces the single
    /// pane and when the last split collapses back into one.
    private func installRoot() {
        // U13 — while a pane is zoomed, *it* is what fills the controller's
        // view; the split tree is still intact underneath, just not in the
        // hierarchy.
        let root = zoomedPane?.view ?? tree.root
        guard root.superview !== view else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// U07 — the arrangement changed, so the saved copy is stale. The write
    /// itself is debounced in `AppDelegate`; this only says that something
    /// moved. A divider drag arrives through the window's own resize
    /// notification, so only the structural changes are reported here.
    func noteLayoutChanged() {
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
    }

    // MARK: - Zoom (U13)

    /// The pane filling the window on its own, or `nil` when the split tree
    /// is on screen.
    ///
    /// **Temporary, and it says so.** Zoom does not change the arrangement:
    /// the tree is untouched, nothing is closed, no child process is
    /// disturbed, and the saved layout keeps describing the splits rather
    /// than the zoom. That is the difference between this and closing the
    /// other panes, and it is the reason the state lives here as one
    /// reference instead of as a second tree.
    private(set) var zoomedPane: ViewController?

    /// Where the zoomed pane's view came from, so unzoom can put it back in
    /// its own slot rather than somewhere that merely looks the same.
    private var zoomOrigin: (superview: NSView, index: Int)?

    /// The arrangement as it was when the zoom began.
    ///
    /// Two jobs, both because the tree is not whole while a pane is zoomed:
    /// it is what `windowState` reports (so U07 never writes "one pane" over
    /// a split), and it is what the dividers are restored from on the way
    /// out — AppKit re-halves a split that loses a subview, so putting the
    /// view back is not the same as putting the layout back.
    private(set) var layoutBeforeZoom: PaneLayout?

    /// U15 — where the last closed pane was, so it can be reopened there.
    /// One deep; see `SplitViewController+Reopen.swift` for why.
    var lastClosedPane: ClosedPane?

    /// The view the saved arrangement is read from: always the split tree,
    /// never whatever happens to be on screen.
    var layoutRoot: NSView? { tree?.root }

    /// Whether a pane is currently zoomed — read by the menu item, which
    /// toggles rather than offering two commands for one gesture.
    var isPaneZoomed: Bool { zoomedPane != nil }

    @objc func toggleZoomPane(_ sender: Any?) {
        if zoomedPane != nil {
            unzoomPane()
        } else {
            zoomFocusedPane()
        }
    }

    /// Fills the window with the focused pane. A single-pane window has
    /// nothing to zoom *from*, so the command does nothing there rather than
    /// entering a state indistinguishable from the one it started in.
    func zoomFocusedPane() {
        guard hasMultiplePanes, let pane = focusedPane, zoomedPane == nil,
            let superview = pane.view.superview,
            let index = superview.subviews.firstIndex(of: pane.view)
        else { return }
        zoomedPane = pane
        zoomOrigin = (superview, index)
        layoutBeforeZoom = windowState(frame: view.window?.frame ?? view.frame)?.layout
        // Detached from its split before the tree root leaves the hierarchy,
        // so AppKit is never asked to hold it in two places at once.
        pane.view.removeFromSuperview()
        installRoot()
        // The pane's grid has to follow the size it now occupies; the other
        // panes keep the size they had, and get a resize each on the way back
        // — a child that is not on screen still has a winsize, and lying to
        // it would strand its output when it reappears.
        view.layoutSubtreeIfNeeded()
        resizeAllPanes()
        applyFocusAppearance(to: pane)
        view.window?.makeFirstResponder(pane.terminalView)
    }

    /// Puts the split tree back exactly as it was.
    func unzoomPane() {
        guard let pane = zoomedPane else { return }
        zoomedPane = nil
        // Back into its own slot in its own split. `installRoot` re-adds the
        // tree root, but the tree's split view lost this child when the pane
        // was zoomed — re-adding only the root would leave a split with one
        // subview and the pane orphaned, which looks correct in a screenshot
        // and is not.
        pane.view.removeFromSuperview()
        if let origin = zoomOrigin, origin.superview.subviews.count >= origin.index {
            origin.superview.addSubview(
                pane.view,
                positioned: origin.index == 0 ? .below : .above,
                relativeTo: origin.superview.subviews.first)
        }
        zoomOrigin = nil
        installRoot()
        if let layout = layoutBeforeZoom { reapplyDividerPositions(layout) }
        layoutBeforeZoom = nil
        view.layoutSubtreeIfNeeded()
        resizeAllPanes()
        applyFocusAppearance(to: pane)
        view.window?.makeFirstResponder(pane.terminalView)
    }

    /// Leaves zoom if `pane` is the zoomed one — a zoomed pane that closes
    /// would otherwise leave the window showing a removed view.
    private func unzoomIfNeeded(closing pane: ViewController) {
        guard zoomedPane === pane else { return }
        // Put it back before it is closed: `SplitTree.close(leaf:)` works on
        // the tree, and a leaf whose view is not in the tree cannot be
        // removed from it.
        unzoomPane()
    }

    /// Every pane re-reads the size it occupies. Called after a zoom in
    /// either direction, where every pane's geometry changed at once.
    private func resizeAllPanes() {
        for pane in panes { pane.resizeSessionToFitView() }
    }

    private func applyFocusAppearance(to pane: ViewController) {
        focusedPane = pane
        for other in panes { other.applyFocusAppearance() }
    }

    // MARK: - Splitting and closing

    @objc func splitRight(_ sender: Any?) { splitFocusedPane(orientation: .columns) }
    @objc func splitDown(_ sender: Any?) { splitFocusedPane(orientation: .rows) }

    func splitFocusedPane(
        orientation: SplitOrientation, workingDirectory: String? = nil, preset: Preset? = nil
    ) {
        guard let focusedPane else { return }
        defer { noteLayoutChanged() }
        // Splitting a zoomed pane means seeing the result, so the zoom ends
        // rather than hiding the pane that was just created.
        unzoomPane()
        // Captured before the split: the node takes the leaf's old frame,
        // and the two halves are pre-set on the subviews so the very first
        // layout already shows a 50/50 split. Without this the new pane is
        // born zero-size and a later `setPosition` visibly corrects it —
        // the "split flashes, then settles" jank.
        let oldFrame = focusedPane.view.frame
        let pane = makePane(
            workingDirectory: workingDirectory ?? focusedPane.session?.workingDirectory,
            initialGridSize: halvedGridSize(of: focusedPane, orientation: orientation),
            preset: preset)
        let node = tree.split(
            leaf: focusedPane.view, orientation: orientation, newLeaf: pane.view)
        node.delegate = self
        if node === tree.root { installRoot() }
        node.frame = oldFrame
        let (firstFrame, secondFrame) = halvedFrames(of: oldFrame, orientation: orientation)
        focusedPane.view.frame = firstFrame
        pane.view.frame = secondFrame
        view.layoutSubtreeIfNeeded()
        let axis = node.isVertical ? node.bounds.width : node.bounds.height
        node.setPosition(axis / 2, ofDividerAt: 0)
        // A split is a one-shot resize, not a drag stream: deliver the new
        // winsize immediately. Leaving it to the debounce window renders
        // the old grid into the new halves for ~100 ms, then visibly jumps.
        focusedPane.endLiveResize()
        pane.endLiveResize()
        updateWindowMinSize()
        // The new pane takes focus, as every split UI does.
        view.window?.makeFirstResponder(pane.terminalView)
    }

    /// The two halves of a frame along the split axis, in the node's own
    /// (flipped) coordinates: the second leaf starts past the divider.
    private func halvedFrames(of frame: NSRect, orientation: SplitOrientation)
        -> (NSRect, NSRect)
    {
        let divider: CGFloat = 1  // .thin dividerStyle
        if orientation == .columns {
            let width = (frame.width - divider) / 2
            return (
                NSRect(x: 0, y: 0, width: width, height: frame.height),
                NSRect(
                    x: width + divider, y: 0,
                    width: frame.width - width - divider, height: frame.height)
            )
        }
        let height = (frame.height - divider) / 2
        return (
            NSRect(x: 0, y: 0, width: frame.width, height: height),
            NSRect(
                x: 0, y: height + divider,
                width: frame.width, height: frame.height - height - divider)
        )
    }

    /// ⌘W / File > Close. With splits the close is the focused pane's; with
    /// one pane left the window's own `performClose` keeps its exact old
    /// meaning (a tabbed window closes the tab, not the group).
    @objc func performClose(_ sender: Any?) {
        guard hasMultiplePanes, let focusedPane else {
            // The window's own close runs through `windowShouldClose`, which
            // is where the whole-window confirmation lives — asking here too
            // would ask twice.
            view.window?.performClose(sender)
            return
        }
        guard confirmClose(
            of: focusedPane.session?.hasForegroundJob == true ? [focusedPane] : [],
            scope: "this pane")
        else { return }
        closePane(focusedPane)
    }

    func closePane(_ pane: ViewController) {
        defer { noteLayoutChanged() }
        unzoomIfNeeded(closing: pane)
        // Recorded before the tree changes: afterwards the split it sat in no
        // longer exists (U15).
        noteClosing(pane)
        pane.teardown()
        let survivingSubtree = tree.close(leaf: pane.view)
        pane.removeFromParent()
        installRoot()
        updateWindowMinSize()
        if let subtree = survivingSubtree, let target = panes.first(where: {
            $0.view === subtree || $0.view.isDescendant(of: subtree)
        }) {
            view.window?.makeFirstResponder(target.terminalView)
        } else {
            invalidateRemainingPanes()
        }
    }

    private func invalidateRemainingPanes() {
        for pane in panes { pane.invalidateDisplay() }
    }

    /// Whole-window teardown (E01) for the close paths that never reach
    /// `closePane` — the red button, a tab's close, ⌘Q. Idempotent through
    /// each pane's own guard, so a pane closed earlier in the same window
    /// is simply skipped.
    func teardown() {
        for pane in panes { pane.teardown() }
    }

    /// The grid size a new pane will actually hold: half the focused pane's
    /// pixel area along the split axis, minus the hairline divider, in cells.
    private func halvedGridSize(of pane: ViewController, orientation: SplitOrientation)
        -> TerminalSize
    {
        let divider: CGFloat = 1  // .thin dividerStyle
        let bounds = pane.view.bounds
        let target =
            orientation == .columns
            ? CGSize(width: (bounds.width - divider) / 2, height: bounds.height)
            : CGSize(width: bounds.width, height: (bounds.height - divider) / 2)
        return pane.gridSize(fitting: target)
    }

    // MARK: - Focus (M5.2)

    /// Recorded from `TerminalView.becomeFirstResponder`: whichever route
    /// took focus, the focused pane is the one holding it.
    func noteFocus(_ pane: ViewController) {
        guard focusedPane !== pane else { return }
        let previous = focusedPane
        focusedPane = pane
        // The cursor only draws in the focused pane, so a focus move is
        // visible damage in both the old and the new pane.
        previous?.invalidateDisplay()
        pane.invalidateDisplay()
        previous?.applyFocusAppearance()
        pane.applyFocusAppearance()
        applyWindowTitle()
    }

    /// The window's title is the focused pane's (M2.8, M5.2) — what is
    /// running, where, and the grid size (`ViewController.applyWindowTitle`).
    /// A title arriving in an unfocused pane waits for focus.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        guard let focusedPane else {
            window.title = "Corta"
            window.representedURL = nil
            return
        }
        focusedPane.applyWindowTitle()
    }

    @objc func moveFocusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func moveFocusRight(_ sender: Any?) { moveFocus(.right) }
    @objc func moveFocusUp(_ sender: Any?) { moveFocus(.up) }
    @objc func moveFocusDown(_ sender: Any?) { moveFocus(.down) }

    private func moveFocus(_ direction: SplitMoveDirection) {
        guard let focusedPane,
            let leaf = tree.leaf(from: focusedPane.view, direction: direction, inContainer: view),
            let target = pane(forLeaf: leaf)
        else { return }
        view.window?.makeFirstResponder(target.terminalView)
    }

    /// `NSUserInterfaceValidations`, not an override: the focus moves only
    /// make sense with more than one pane.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveFocusLeft(_:)), #selector(moveFocusRight(_:)),
            #selector(moveFocusUp(_:)), #selector(moveFocusDown(_:)):
            return tree != nil && tree.leafCount > 1
        case #selector(reopenClosedPane(_:)):
            return canReopenClosedPane
        case #selector(toggleZoomPane(_:)):
            // U13 — one command, two names. A checkmark would say the pane is
            // zoomed but not what the item now does; the title says both, and
            // there is only one gesture to learn either way. Disabled in a
            // single-pane window, which has nothing to zoom *from*.
            menuItem.title =
                isPaneZoomed
                ? L10n.text("command.unzoomPane") : L10n.text("command.zoomPane")
            return isPaneZoomed || (tree != nil && tree.leafCount > 1)
        default:
            return true
        }
    }

    // MARK: - Font size (Track D, broadcast across the tree)

    /// ⌘= / ⌘- / ⌘0 apply to every pane in the window: the panes share the
    /// window's resize increments and minimum size, which are single values
    /// derived from one cell geometry.
    func setFontSizeForAllPanes(_ size: CGFloat, isZoomed: Bool) {
        for pane in panes {
            pane.setFontSize(size)
            // B09 — set together with the size, on every pane, so
            // `configurationChanged` (which runs per pane) agrees about
            // whether this window is zoomed no matter which pane it asks.
            pane.isFontSizeZoomed = isZoomed
        }
        if hasMultiplePanes {
            // The window re-fit in `setFontSize` is the single-pane path —
            // no window size keeps every pane's grid intact at once. The
            // pane frames stay; refit each grid to its pixel area at the
            // new cell metrics.
            for pane in panes { pane.resizeSessionToFitView() }
        }
        updateWindowMinSize()
    }

    // MARK: - Minimum sizes (M5.4)

    /// The window's minimum content size is the tree's minimum plus the
    /// chrome; the divider constraints below are what keep a drag from
    /// crushing a pane past its minimum first.
    func updateWindowMinSize() {
        guard let window = view.window, let pane = panes.first else { return }
        let treeMinimum = tree.minimumSize(
            of: tree.root, leafSize: leafMinimumSize, dividerThickness: 1)
        window.contentMinSize = NSSize(
            width: treeMinimum.width,
            height: treeMinimum.height + pane.windowChrome)
    }

    private func leafMinimumSize(_ leaf: NSView) -> CGSize {
        pane(forLeaf: leaf)?.minimumContentSize ?? .zero
    }

    private func minimumAxis(of subtree: NSView, vertical: Bool) -> CGFloat {
        let size = tree.minimumSize(
            of: subtree, leafSize: leafMinimumSize, dividerThickness: 1)
        return vertical ? size.width : size.height
    }
}

/// The window's content view. With `.fullSizeContentView` the content spans
/// the titlebar band, and AppKit hit-tests the content first there — which
/// is why a terminal window's top bar usually can't be dragged or
/// double-clicked to zoom. Passing the chrome band (titlebar, plus the tab
/// bar when tabbed) back to the window frame restores both.
final class WindowContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window {
            let chrome = window.frame.height - window.contentLayoutRect.height
            // Unflipped: the top band is the high-y end. The band contains
            // no cells and no controls (the search bar floats below it), so
            // nothing is lost by giving it to the frame.
            if chrome > 0, convert(point, from: superview).y > bounds.height - chrome {
                return nil
            }
        }
        return super.hitTest(point)
    }
}

extension SplitViewController: NSSplitViewDelegate {
    /// A divider drag may not push a subtree below its minimum; without
    /// these the split view happily crushes a pane to zero and the session
    /// gets a 0-column winsize.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMinimumPosition
            + minimumAxis(of: splitView.subviews[dividerIndex], vertical: splitView.isVertical)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMaximumPosition
            - minimumAxis(of: splitView.subviews[dividerIndex + 1], vertical: splitView.isVertical)
    }
}
