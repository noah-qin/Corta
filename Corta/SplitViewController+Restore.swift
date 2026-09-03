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
        guard let root = view.subviews.first else { return nil }
        return WindowState(frame: WindowState.Frame(frame), layout: layout(of: root))
    }

    private func layout(of subtree: NSView) -> PaneLayout {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else {
            return .pane(directory: pane(forView: subtree)?.session?.workingDirectory)
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
        rebuild(layout, at: root)
        view.layoutSubtreeIfNeeded()
        applyDividerPositions(layout, subtree: view.subviews.first)
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
        // The first pane keeps focus, as it would after a fresh launch —
        // `splitFocusedPane` moves focus to each new pane as it goes.
        view.window?.makeFirstResponder(root.terminalView)
    }

    private func rebuild(_ node: PaneLayout, at pane: ViewController) {
        guard case .split(let vertical, _, let first, let second) = node else { return }
        focusedPane = pane
        splitFocusedPane(
            orientation: vertical ? .columns : .rows,
            workingDirectory: second.firstDirectory)
        guard let created = focusedPane, created !== pane else { return }
        rebuild(first, at: pane)
        rebuild(second, at: created)
    }

    /// Second pass: the dividers, once every split exists and the tree has
    /// laid out. Done separately because splitting re-halves everything it
    /// touches, so positions set during the build would be overwritten by the
    /// next split below them.
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
