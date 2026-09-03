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
    private(set) var focusedPane: ViewController?
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

    override func viewDidLoad() {
        super.viewDidLoad()
        let pane = makePane(workingDirectory: nil, initialGridSize: nil)
        focusedPane = pane
        tree = SplitTree(root: pane.view)
        installRoot()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard !didSetUpWindow, let window = view.window, let pane = focusedPane else { return }
        didSetUpWindow = true
        pane.didSizeWindow = true
        let metrics = pane.terminalRenderer.pointMetrics
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
        window.styleMask.insert(.fullSizeContentView)
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
        // height on the first call. The size is therefore corrected once at
        // the first settled layout (`correctInitialWindowSize`); the
        // session is born at the target grid size and nothing is delivered
        // before then (`sizeSettled` gate), so no transient winsize reaches
        // the child (D.1).
        //
        // A window joining a tab group (File > New Tab) takes the group's
        // frame — sizing it here would resize the shared window, which is
        // the visible "the whole window moves when a tab opens" jump.
        if window.tabbedWindows == nil {
            window.setContentSize(pane.initialWindowContentSize)
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
        pane.terminalView.drawNow()
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
            correctInitialWindowSize()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window, didSetUpWindow else { return }
        // A tab bar appearing or disappearing changes the chrome height
        // without any user resize; AppKit answers by shrinking the content
        // area, which visibly pushes the grid down. Absorb the delta into
        // the frame instead: the window grows downward (the titlebar stays
        // put) and every pane keeps its row count.
        let chrome = window.frame.height - window.contentLayoutRect.height
        if let last = lastChromeHeight, chrome != last, !window.inLiveResize,
            !window.styleMask.contains(.fullScreen)
        {
            var frame = window.frame
            frame.origin.y -= chrome - last
            frame.size.height += chrome - last
            window.setFrame(frame, display: true)
        }
        lastChromeHeight = chrome
    }

    /// The one-time correction for `setContentSize` mismeasuring the chrome
    /// on the first call (see `viewWillAppear`). Sized by frame because that
    /// is what `setContentSize` now drives; the pane area spans the frame
    /// with `.fullSizeContentView`.
    private func correctInitialWindowSize() {
        guard !didCorrectWindowSize, let window = view.window, let pane = focusedPane
        else { return }
        didCorrectWindowSize = true
        // A tab takes the group's frame; nothing to correct.
        guard window.tabbedWindows == nil else { return }
        let target = pane.initialWindowContentSize
        guard abs(window.frame.height - target.height) > 1
            || abs(window.frame.width - target.width) > 1
        else { return }
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
    private func makePane(workingDirectory: String?, initialGridSize: TerminalSize?) -> ViewController {
        let pane = ViewController()
        // M5.5: a split pane opens where the focused pane is, via OSC 7
        // (M2.8); nil (no report yet) falls back to the home directory.
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
        let root = tree.root
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

    // MARK: - Splitting and closing

    @objc func splitRight(_ sender: Any?) { splitFocusedPane(orientation: .columns) }
    @objc func splitDown(_ sender: Any?) { splitFocusedPane(orientation: .rows) }

    func splitFocusedPane(orientation: SplitOrientation) {
        guard let focusedPane else { return }
        // Captured before the split: the node takes the leaf's old frame,
        // and the two halves are pre-set on the subviews so the very first
        // layout already shows a 50/50 split. Without this the new pane is
        // born zero-size and a later `setPosition` visibly corrects it —
        // the "split flashes, then settles" jank.
        let oldFrame = focusedPane.view.frame
        let pane = makePane(
            workingDirectory: focusedPane.session.workingDirectory,
            initialGridSize: halvedGridSize(of: focusedPane, orientation: orientation))
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
            view.window?.performClose(sender)
            return
        }
        closePane(focusedPane)
    }

    func closePane(_ pane: ViewController) {
        // The bar's key monitor outlives the pane if it is left open.
        pane.closeSearchBar()
        pane.session.stop()
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

    /// The window's title is the focused pane's OSC 0/2 title (M2.8); a
    /// title arriving in an unfocused pane waits for focus.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        let title = focusedPane?.session.windowTitle
        window.title = title?.isEmpty == false ? title! : "Corta"
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
        default:
            return true
        }
    }

    // MARK: - Font size (Track D, broadcast across the tree)

    /// ⌘= / ⌘- / ⌘0 apply to every pane in the window: the panes share the
    /// window's resize increments and minimum size, which are single values
    /// derived from one cell geometry.
    func setFontSizeForAllPanes(_ size: CGFloat) {
        for pane in panes { pane.setFontSize(size) }
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
