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
import CortaTerminal

/// The window's content controller: owns the split tree, one pane
/// (`ViewController`, one `TerminalSession`) per leaf (D07), and the focus
/// that routes input to one of them. Window-level setup lives here, since
/// N panes still share one window.
final class SplitViewController: NSViewController {
    private var tree: SplitTree!
    private let systemStatusBar = SystemStatusBar(frame: .zero)
    let inputSourceToolbarHost = NSView(frame: CGRect(x: 0, y: 0, width: 28, height: 18))
    var inputSourceToolbarSpacer: NSToolbarItem?
    private var statusBarHeightConstraint: NSLayoutConstraint?
    var statusBarHeight: CGFloat { ConfigurationStore.shared.configuration.statusBar ? SystemStatusBar.height : 0 }
    /// The pane that receives input. Set by `noteFocus` from
    /// `TerminalView.becomeFirstResponder`, so every route to focus funnels
    /// through one place; `SplitViewController+Restore` sets it to rebuild a
    /// saved layout through the same split path as ⌘D.
    var focusedPane: ViewController?
    /// Window setup ran (`viewWillAppear`); later split panes take
    /// `didSizeWindow` from this.
    private var didSetUpWindow = false
    /// True once the content view fills its window's frame — the
    /// transient-layout gate (D15). Checked here because a pane in a split
    /// legitimately doesn't fill the window. Set in `viewWillLayout` so panes
    /// see it in the pass that settles.
    private(set) var layoutSettled = false
    /// The one-time frame correction ran, or the window is a tab and takes the
    /// group's frame.
    private var didCorrectWindowSize = false
    /// Both startup gates: laid out at full height, frame corrected to fit the
    /// initial grid.
    var sizeSettled: Bool { layoutSettled && didCorrectWindowSize }
    /// The chrome height at the last layout, for absorbing tab-bar changes
    /// into the frame.
    private var lastChromeHeight: CGFloat?
    var isJoiningTabGroup = false

    var panes: [ViewController] { children.compactMap { $0 as? ViewController } }
    var hasMultiplePanes: Bool { tree?.leafCount ?? 1 > 1 }

    /// What the next storyboard-instantiated window's root pane spawns as.
    ///
    /// **Set before `instantiateInitialController`, not after (D16).** The
    /// storyboard loads the content view — and the root pane spawns its shell
    /// — inside that call, so a value assigned to the controller afterwards
    /// never reaches the root pane. `AppDelegate.instantiateWindowController(setup:)`
    /// stages it here and `viewDidLoad` takes it.
    struct Setup {
        var restore: WindowState?
        var preset: Preset?
        /// The directory an App Intent asked for; ignored when `restore` or
        /// `preset` names one.
        var workingDirectory: String?
    }
    static var pendingSetup: Setup?

    /// The layout being restored: taken in `viewDidLoad` (the root pane needs
    /// its directory at spawn), consumed in `viewWillAppear` (the splits need
    /// the final frame).
    var pendingRestore: WindowState?

    /// The preset the first pane spawned from.
    var pendingPreset: Preset?

    override func viewDidLoad() {
        super.viewDidLoad()
        let setup = Self.pendingSetup
        Self.pendingSetup = nil
        // Staged values win; a value set on a hand-built controller before its
        // view loads (tests do this) is kept.
        if let restore = setup?.restore { pendingRestore = restore }
        if let preset = setup?.preset { pendingPreset = preset }
        // Resolved by name against the current config, so a restored window gets
        // its preset's shell and environment back; a preset renamed since degrades
        // to directory-only.
        let restoredPreset = pendingRestore?.layout.firstPresetName.flatMap { name in
            ConfigurationStore.shared.configuration.presets.first { $0.name == name }
        }
        let pane = makePane(
            workingDirectory: pendingRestore?.layout.firstDirectory ?? setup?.workingDirectory,
            initialGridSize: nil, preset: pendingPreset ?? restoredPreset)
        focusedPane = pane
        tree = SplitTree(root: pane.view)
        systemStatusBar.onVisibilityChange = { [weak self] in self?.updateStatusBarLayout() }
        installRoot()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard !didSetUpWindow, let window = view.window, let pane = focusedPane else { return }
        didSetUpWindow = true
        pane.didSizeWindow = true
        // A pane that failed to build (`PaneFailureView`) has no atlas to
        // measure; keep the storyboard's size.
        guard let metrics = pane.terminalRenderer?.pointMetrics else {
            didSetUpWindow = false
            return
        }
        window.title = "Corta"
        installToolbar(on: window)
        window.tabbingMode = .automatic
        // Chrome follows the system appearance; the terminal surface stays dark.
        window.appearance = nil
        // Content runs under the titlebar (`.fullSizeContentView`); the grid's
        // top inset is measured at runtime (`windowChrome`). Set here, not in
        // `viewDidAppear`: the style mask must be final before the first layout
        // (D15). Inserting the flag loses a chrome height from the frame, so the
        // frame is captured to restore below.
        let frameBeforeStyleChange = window.frame
        window.styleMask.insert(.fullSizeContentView)
        // Its content is a live process, not a document. Left restorable, AppKit
        // re-applied a stale saved frame after the sizing below.
        window.isRestorable = false
        // Let the Metal layer's translucent clear show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        updateWindowMinSize()
        // With `.fullSizeContentView`, `setContentSize` sizes the frame and
        // mismeasures the chrome by a titlebar on the first call; the size is
        // corrected once in `viewDidAppear`, and `sizeSettled` holds back every
        // winsize until then. A window joining a tab group takes the group's
        // frame; sizing it would move the whole window.
        if window.tabbedWindows == nil {
            window.setContentSize(pane.initialWindowContentSize)
        } else if window.frame != frameBeforeStyleChange {
            // Undo the chrome height the style-mask insert took. A tab keeps the
            // group's frame, so without this every ⌘T shrank the shared window.
            window.setFrame(frameBeforeStyleChange, display: false)
        }
        // Nothing else claims first responder; without it keyDown never fires
        // and First Responder menu actions (⌘V, ⌘=, ⌘D) dead-end.
        window.makeFirstResponder(pane.terminalView)
        // Paint one frame before the window shows, or it flashes the desktop
        // until the Metal layer first presents.
        view.layoutSubtreeIfNeeded()
        pane.terminalView?.drawNow()

        // The splits go last: they halve the window's final frame.
        if let restore = pendingRestore {
            pendingRestore = nil
            // The saved frame is authoritative; skip the default-grid correction.
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
        // AppKit's final `.fullSizeContentView` frame adjustment lands after
        // the last pre-display layout; correcting earlier turned 120×30 into
        // 120×27. The session is still behind the `sizeSettled` gate.
        correctInitialWindowSize()
        view.layoutSubtreeIfNeeded()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        // See `layoutSettled`. Anything short of the frame is the pre-style-mask
        // transient (observed: 522pt content in a 554pt frame).
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

    /// A tab bar appearing or disappearing changes the chrome height; AppKit
    /// would shrink the content area and cost every pane rows. Absorb the
    /// delta into the frame instead (the window grows downward).
    ///
    /// Called from `viewDidLayout`, and from `AppDelegate.newTab` for the
    /// window a new tab covers, which never lays out again on its own.
    func absorbChromeChange() {
        // Before setup is over `contentLayoutRect` is still the pre-sizing area
        // (observed at origin -302), and absorbing it jumps the window.
        guard !isJoiningTabGroup, let window = view.window, didSetUpWindow, sizeSettled, window.isVisible
        else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let last = lastChromeHeight
        // Recorded before `setFrame`, which lays out reentrantly and would
        // otherwise absorb the same delta twice.
        lastChromeHeight = chrome
        guard let last, chrome != last, !window.inLiveResize,
            !window.styleMask.contains(.fullScreen)
        else { return }
        var frame = window.frame
        frame.origin.y -= chrome - last
        frame.size.height += chrome - last
        window.setFrame(frame, display: true)
    }

    /// The chrome changed under a window that must keep its frame: a restored
    /// window rejoining its tab group (`AppDelegate.regroupRestoredTabs`),
    /// whose saved frame already includes the tab bar. Records the chrome so
    /// it is not absorbed, then lays the panes out — an unselected tab never
    /// lays out on its own.
    func adoptChromeWithoutAbsorbing() {
        guard let window = view.window else { return }
        lastChromeHeight = window.frame.height - window.contentLayoutRect.height
        for pane in panes { pane.view.needsLayout = true }
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.invalidateDisplay()
        }
    }

    /// The one-time correction for `setContentSize` mismeasuring the chrome
    /// (see `viewWillAppear`), sized by frame.
    private func correctInitialWindowSize() {
        guard !didCorrectWindowSize, let window = view.window, let pane = focusedPane
        else { return }
        // A tab takes the group's frame; nothing to correct.
        guard window.tabbedWindows == nil else {
            didCorrectWindowSize = true
            return
        }
        var target = pane.initialWindowContentSize
        target.height += statusBarHeight
        didCorrectWindowSize = true
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        // Initial sizing and restoration share the same Dock/menu-bar bounds.
        // Clamp after AppKit's final chrome correction and before PTY sizing.
        window.setFrame(WindowState.Frame(frame).onScreen(preferredScreen: window.screen, minimumSize: .zero), display: true)
    }

    // MARK: - Panes

    /// Creates a pane and its session, force-loading the view so the shell
    /// spawns at the target grid size and directory rather than reflowing.
    private func makePane(
        workingDirectory: String?, initialGridSize: TerminalSize?, preset: Preset? = nil
    ) -> ViewController {
        let pane = ViewController()
        // Before `pane.view` loads: the preset supplies spawn settings.
        pane.preset = preset
        // Opens where the focused pane is (OSC 7), else home. The directory is
        // already host-filtered, so a remote path never reaches a local spawn.
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

    /// The terminal root changes identity on the first split and last collapse;
    /// the optional status bar remains anchored beneath it.
    private func installRoot() {
        // A zoomed pane fills the view; the tree stays intact, just detached.
        let root = zoomedPane?.view ?? tree.root
        guard root.superview !== view else { return }
        view.subviews.filter { $0 !== systemStatusBar }.forEach { $0.removeFromSuperview() }
        if systemStatusBar.superview == nil {
            systemStatusBar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(systemStatusBar)
            let height = systemStatusBar.heightAnchor.constraint(equalToConstant: statusBarHeight)
            statusBarHeightConstraint = height
            NSLayoutConstraint.activate([
                systemStatusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                systemStatusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                systemStatusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor), height,
            ])
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root, positioned: .below, relativeTo: systemStatusBar)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: systemStatusBar.topAnchor),
        ])
    }

    private func updateStatusBarLayout() {
        statusBarHeightConstraint?.constant = statusBarHeight
        updateWindowMinSize()
        view.layoutSubtreeIfNeeded()
        for pane in panes { pane.resizeSessionToFitView(); pane.invalidateDisplay() }
    }

    /// Marks the saved arrangement stale; `AppDelegate` debounces the write.
    /// Divider drags arrive through the window's resize notification.
    func noteLayoutChanged() {
        (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
    }

    // MARK: - Zoom

    /// The pane filling the window, or `nil`. Zoom is temporary: the tree,
    /// the processes and the saved layout are untouched, which is why it is
    /// one reference rather than a second tree.
    private(set) var zoomedPane: ViewController?

    /// Where the zoomed pane's view came from, so unzoom restores its slot.
    private var zoomOrigin: (superview: NSView, index: Int)?

    /// The arrangement when the zoom began: what `windowState` saves while
    /// zoomed, and what the dividers are restored from — AppKit re-halves a
    /// split that loses a subview.
    private(set) var layoutBeforeZoom: PaneLayout?

    /// Where the last closed pane was, for reopening; one deep
    /// (`SplitViewController+Reopen.swift`).
    var lastClosedPane: ClosedPane?

    /// The split tree, never whatever is on screen.
    var layoutRoot: NSView? { tree?.root }

    var isPaneZoomed: Bool { zoomedPane != nil }

    @objc func toggleZoomPane(_ sender: Any?) {
        if zoomedPane != nil {
            unzoomPane()
        } else {
            zoomFocusedPane()
        }
    }

    /// Fills the window with the focused pane; a no-op with one pane.
    func zoomFocusedPane() {
        guard hasMultiplePanes, let pane = focusedPane, zoomedPane == nil,
            let superview = pane.view.superview,
            let index = superview.subviews.firstIndex(of: pane.view)
        else { return }
        zoomedPane = pane
        zoomOrigin = (superview, index)
        layoutBeforeZoom = windowState(frame: view.window?.frame ?? view.frame)?.layout
        // Detach first, so AppKit never holds the view in two places.
        pane.view.removeFromSuperview()
        installRoot()
        // The other panes get their resize on the way back; hidden children
        // still have a winsize.
        view.layoutSubtreeIfNeeded()
        resizeAllPanes()
        applyFocusAppearance(to: pane)
        view.window?.makeFirstResponder(pane.terminalView)
    }

    func unzoomPane() {
        guard let pane = zoomedPane else { return }
        zoomedPane = nil
        // Back into its own slot: the split lost this child on zoom, and
        // re-adding only the root would orphan it.
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

    /// Leaves zoom if `pane` is zoomed, so a close never leaves a removed
    /// view on screen.
    private func unzoomIfNeeded(closing pane: ViewController) {
        guard zoomedPane === pane else { return }
        // `SplitTree.close(leaf:)` can't remove a leaf that isn't in the tree.
        unzoomPane()
    }

    /// Every pane re-reads its size; a zoom changes all of them at once.
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
        unzoomPane()
        // The node takes the leaf's old frame and the halves are pre-set, so the
        // first layout is already 50/50 instead of flashing a zero-size pane.
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
        // A split is one resize, not a drag: deliver now rather than render the
        // old grid into the halves through the debounce window.
        focusedPane.endLiveResize()
        pane.endLiveResize()
        updateWindowMinSize()
        view.window?.makeFirstResponder(pane.terminalView)
    }

    /// The two halves of a frame, in the node's flipped coordinates.
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

    /// ⌘W closes the focused pane; with one pane left it is the window's
    /// own close (a tab closes the tab).
    @objc func performClose(_ sender: Any?) {
        guard hasMultiplePanes, let focusedPane else {
            // `windowShouldClose` asks for confirmation; asking here would ask twice.
            view.window?.performClose(sender)
            return
        }
        guard confirmClose(
            of: focusedPane.session?.hasForegroundJob == true ? [focusedPane] : [],
            scope: L10n.text("close.scope.pane"))
        else { return }
        closePane(focusedPane)
    }

    func closePane(_ pane: ViewController) {
        defer { noteLayoutChanged() }
        unzoomIfNeeded(closing: pane)
        // Before the tree changes, while its split still exists.
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

    /// Whole-window teardown for closes that bypass `closePane` (red button,
    /// tab close, ⌘Q). Idempotent per pane.
    func teardown() {
        systemStatusBar.stop()
        for pane in panes { pane.teardown() }
    }

    /// Half the focused pane's pixel area, minus the divider, in cells.
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

    // MARK: - Focus

    func noteFocus(_ pane: ViewController) {
        guard focusedPane !== pane else { return }
        let previous = focusedPane
        focusedPane = pane
        // The cursor draws only in the focused pane: both panes need a redraw.
        previous?.invalidateDisplay()
        pane.invalidateDisplay()
        previous?.applyFocusAppearance()
        pane.applyFocusAppearance()
        applyWindowTitle()
    }

    /// The focused pane's title; a title in an unfocused pane waits for focus.
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

    /// Focus moves need more than one pane.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveFocusLeft(_:)), #selector(moveFocusRight(_:)),
            #selector(moveFocusUp(_:)), #selector(moveFocusDown(_:)):
            return tree != nil && tree.leafCount > 1
        case #selector(reopenClosedPane(_:)):
            return canReopenClosedPane
        case #selector(toggleZoomPane(_:)):
            // The title says what the item does now, which a checkmark wouldn't.
            menuItem.title =
                isPaneZoomed
                ? L10n.text("command.unzoomPane") : L10n.text("command.zoomPane")
            return isPaneZoomed || (tree != nil && tree.leafCount > 1)
        default:
            return true
        }
    }

    // MARK: - Font size (broadcast across the tree)

    /// ⌘= / ⌘- / ⌘0 apply to every pane: they share the window's resize
    /// increments and minimum size, derived from one cell geometry.
    func setFontSizeForAllPanes(_ size: CGFloat, isZoomed: Bool) {
        for pane in panes {
            pane.setFontSize(size)
            // On every pane, so each pane's `configurationChanged` agrees.
            pane.isFontSizeZoomed = isZoomed
        }
        if hasMultiplePanes {
            // No window size keeps every grid intact; keep the frames and refit each
            // grid instead of the single-pane window re-fit.
            for pane in panes { pane.resizeSessionToFitView() }
        }
        updateWindowMinSize()
    }

    // MARK: - Minimum sizes

    /// The tree's minimum plus the chrome; the divider constraints keep drags
    /// from crushing a pane first.
    func updateWindowMinSize() {
        guard let window = view.window, let pane = panes.first else { return }
        let treeMinimum = tree.minimumSize(
            of: tree.root, leafSize: leafMinimumSize, dividerThickness: 1)
        window.contentMinSize = NSSize(
            width: treeMinimum.width,
            height: treeMinimum.height + pane.windowChrome + statusBarHeight)
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

/// The window's content view. With `.fullSizeContentView` the content
/// covers the titlebar band and wins hit-testing there; passing the
/// chrome band back to the frame restores titlebar drag and double-click.
final class WindowContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window {
            let chrome = window.frame.height - window.contentLayoutRect.height
            // Unflipped: the top band is high y. It holds no cells or controls.
            if chrome > 0, convert(point, from: superview).y > bounds.height - chrome {
                return nil
            }
        }
        return super.hitTest(point)
    }
}

extension SplitViewController: NSSplitViewDelegate {
    /// Keeps a divider drag from crushing a pane to a 0-column winsize.
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
