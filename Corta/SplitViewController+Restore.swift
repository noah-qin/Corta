import Cocoa
import CortaTerminal

/// M7.4, window side: turning the live split tree into a `PaneLayout` and
/// back again.
///
/// The two directions are deliberately asymmetric. Capturing walks the view
/// hierarchy, which *is* the tree (`SplitTree`), so there is nothing to keep
/// in sync. Rebuilding replays the same `splitFocusedPane` the user's own
/// ⌘D takes, rather than constructing split views directly — a second way to
/// build the tree would be a second place for the divider maths, the winsize
/// delivery and the focus rules to disagree.
extension SplitViewController {
    // MARK: - Capture

    func windowState(frame: NSRect) -> WindowState? {
        // The *tree*, not `view.subviews.first`. While a pane is zoomed
        // (U13) the controller's view holds that pane alone, and reading the
        // hierarchy would save "one pane" as the arrangement — discarding
        // the splits, and, since U07 writes the arrangement as it changes,
        // writing that loss straight to disk. Zoom is temporary and the saved
        // layout has to keep saying so.
        // While zoomed the tree is not whole — the zoomed pane's view is out
        // of it, so the split it came from has one subview and would read as
        // a plain pane. The layout recorded on the way in is what the
        // arrangement still is.
        let (tabGroupID, tabIndex, isSelectedTab) = tabState()
        if let zoomed = layoutBeforeZoom {
            return WindowState(
                frame: WindowState.Frame(frame), layout: zoomed, tabGroupID: tabGroupID,
                tabIndex: tabIndex, isSelectedTab: isSelectedTab)
        }
        guard let root = layoutRoot else { return nil }
        return WindowState(
            frame: WindowState.Frame(frame), layout: layout(of: root), tabGroupID: tabGroupID,
            tabIndex: tabIndex, isSelectedTab: isSelectedTab)
    }

    /// B09 — this window's place in its native tab group, if any. `nil`
    /// group/index for a window that was never tabbed; AppKit groups tabbed
    /// windows only by having the same `tabbingIdentifier` and does not
    /// number them itself, so the index is this window's position in
    /// `tabbedWindows` order at save time.
    private func tabState() -> (groupID: String?, index: Int?, isSelected: Bool) {
        guard let window = view.window, let tabbed = window.tabbedWindows, tabbed.count > 1
        else { return (nil, nil, true) }
        let index = tabbed.firstIndex(of: window)
        return (window.tabbingIdentifier, index, window.tabGroup?.selectedWindow === window)
    }

    private func layout(of subtree: NSView) -> PaneLayout {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else {
            let pane = pane(forView: subtree)
            return .pane(
                directory: pane?.session?.workingDirectory, presetName: pane?.preset?.name,
                isFocused: pane === focusedPane)
        }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        let first = split.subviews[0].frame
        let extent = split.isVertical ? first.width : first.height
        return .split(
            vertical: split.isVertical,
            // Guarded: a window laid out at zero (never shown, or mid-tab
            // animation) would otherwise save a divide-by-zero as `nan`,
            // which JSON cannot even encode.
            position: axis > 0 ? Double(extent / axis) : 0.5,
            first: layout(of: split.subviews[0]),
            second: layout(of: split.subviews[1]))
    }

    private func pane(forView view: NSView) -> ViewController? {
        panes.first { $0.view === view }
    }

    // MARK: - Restore

    /// Rebuilds `layout` around the window's existing single pane, which was
    /// already created — and spawned in the right directory, via
    /// `PaneLayout.firstDirectory` — by `viewDidLoad`.
    ///
    /// Called once the window has settled, because a split needs real frames
    /// to halve and a divider fraction needs an axis to be a fraction of.
    func restore(layout: PaneLayout) {
        guard let root = focusedPane else { return }
        var focusTarget: ViewController?
        rebuild(layout, at: root, focusTarget: &focusTarget)
        view.layoutSubtreeIfNeeded()
        applyDividerPositions(layout, subtree: view.subviews.first)
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
        // B09 — whichever pane's saved node was `isFocused`, or the first
        // pane as before (`splitFocusedPane` moves focus to each new pane as
        // it goes, so without a match this is where it already landed) for
        // data saved before that field existed.
        view.window?.makeFirstResponder((focusTarget ?? root).terminalView)
    }

    /// A preset resolved by name against the *current* config file — never
    /// the one that was active when the window was saved, which may not
    /// even exist anymore. A name that no longer resolves (renamed or
    /// deleted since) degrades to directory-only exactly as if the pane had
    /// never been launched from a preset at all (B09).
    private func resolvedPreset(named name: String?) -> Preset? {
        guard let name else { return nil }
        return ConfigurationStore.shared.configuration.presets.first { $0.name == name }
    }

    private func rebuild(_ node: PaneLayout, at pane: ViewController, focusTarget: inout ViewController?) {
        switch node {
        case .pane(_, _, let isFocused):
            if isFocused { focusTarget = pane }
        case .split(let vertical, _, let first, let second):
            focusedPane = pane
            splitFocusedPane(
                orientation: vertical ? .columns : .rows,
                workingDirectory: second.firstDirectory,
                preset: resolvedPreset(named: second.firstPresetName))
            guard let created = focusedPane, created !== pane else { return }
            rebuild(first, at: pane, focusTarget: &focusTarget)
            rebuild(second, at: created, focusTarget: &focusTarget)
        }
    }

    /// Second pass: the dividers, once every split exists and the tree has
    /// laid out. Done separately because splitting re-halves everything it
    /// touches, so positions set during the build would be overwritten by the
    /// next split below them.
    /// Re-applies a recorded arrangement's dividers to the tree as it stands
    /// — used on the way out of zoom (U13), where the pane's view left its
    /// split and came back, and AppKit re-halved what was left behind.
    func reapplyDividerPositions(_ layout: PaneLayout) {
        view.layoutSubtreeIfNeeded()
        applyDividerPositions(layout, subtree: layoutRoot)
        view.layoutSubtreeIfNeeded()
    }

    private func applyDividerPositions(_ node: PaneLayout, subtree: NSView?) {
        guard case .split(_, let position, let first, let second) = node,
            let split = subtree as? NSSplitView, split.subviews.count == 2
        else { return }
        applyDividerPositions(first, subtree: split.subviews[0])
        applyDividerPositions(second, subtree: split.subviews[1])
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        guard axis > 0 else { return }
        split.setPosition(axis * CGFloat(position), ofDividerAt: 0)
    }
}
