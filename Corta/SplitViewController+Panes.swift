import Cocoa
import CortaTerminal

/// Pane geometry from the keyboard (M7.8) and the "something is still
/// running" close confirmation (M7.5).
///
/// Both are window-level, so they live beside the split tree rather than in a
/// pane: a resize moves a divider that two panes share, and a close has to
/// ask every session in the subtree being closed, not just the focused one.
extension SplitViewController {
    // MARK: - Resizing panes from the keyboard

    @objc func growPaneHorizontally(_ sender: Any?) { resizeFocusedPane(vertical: true, steps: 1) }
    @objc func shrinkPaneHorizontally(_ sender: Any?) { resizeFocusedPane(vertical: true, steps: -1) }
    @objc func growPaneVertically(_ sender: Any?) { resizeFocusedPane(vertical: false, steps: 1) }
    @objc func shrinkPaneVertically(_ sender: Any?) { resizeFocusedPane(vertical: false, steps: -1) }

    /// Moves the divider the focused pane sits against, by whole cells.
    ///
    /// Whole cells, not points: the grid is the unit the user is actually
    /// adjusting, and a point-sized step would spend most presses inside one
    /// column and then jump. It is also what makes a press always change
    /// something — the divider constraints (M5.4) clamp the result, so a pane
    /// already at its minimum simply stops.
    ///
    /// - Parameter vertical: whether to move a *vertical* divider, i.e.
    ///   change widths. The nearest ancestor node with that orientation is
    ///   the one that owns the edge; in a nested tree the pane's immediate
    ///   parent may split the other way.
    private func resizeFocusedPane(vertical: Bool, steps: CGFloat) {
        guard let focusedPane else { return }
        var child: NSView = focusedPane.view
        var node = child.superview as? NSSplitView
        while let current = node, current.isVertical != vertical {
            child = current
            node = current.superview as? NSSplitView
        }
        guard let split = node, let index = split.subviews.firstIndex(of: child),
            split.subviews.count == 2
        else { return }

        let metrics = focusedPane.terminalRenderer.pointMetrics
        let step = vertical ? metrics.cellWidth : metrics.cellHeight
        // Every node holds exactly two children (`SplitTree`), so there is
        // one divider and its position is the first subview's extent. An
        // `NSSplitView` is flipped, so for a horizontal divider that extent
        // is measured from the top.
        let first = split.subviews[0].frame
        let position = vertical ? first.width : first.height
        // Growing the *second* child means moving the divider the other way.
        let direction: CGFloat = index == 0 ? 1 : -1
        split.setPosition(position + direction * steps * step, ofDividerAt: 0)
        deliverPaneSizes()
    }

    /// Splits every node down the middle, recursively — the escape hatch
    /// after a run of resizes, and the only way back to the layout a fresh
    /// split produced.
    @objc func equalizePanes(_ sender: Any?) {
        equalize(view.subviews.first)
        deliverPaneSizes()
    }

    private func equalize(_ subtree: NSView?) {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else { return }
        for child in split.subviews { equalize(child) }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition(axis / 2, ofDividerAt: 0)
    }

    /// A keyboard resize is a one-shot change, not a drag stream: deliver the
    /// new winsize now rather than after the debounce window, or the grid
    /// visibly lags the divider by a tenth of a second per press.
    private func deliverPaneSizes() {
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
    }

    // MARK: - Closing with something still running (M7.5)

    /// Every pane in the window whose shell has a foreground job.
    var panesWithRunningJobs: [ViewController] {
        panes.filter { $0.session?.hasForegroundJob == true }
    }

    /// Asks before discarding work. Returns true when the close should go
    /// ahead.
    ///
    /// The check is the pty's foreground process group, not a heuristic on
    /// output: the shell hands the terminal to the job it starts, so a
    /// foreground group that is not the shell *is* a running command. A bare
    /// prompt therefore never prompts, which is what keeps ⌘W feeling like
    /// ⌘W.
    func confirmClose(of running: [ViewController], scope: String) -> Bool {
        guard ConfigurationStore.shared.configuration.confirmClose, !running.isEmpty else {
            return true
        }
        let names = running.compactMap { $0.session?.foregroundProcessName }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(scope) while something is running?"
        alert.informativeText =
            names.isEmpty
            ? "A process is still running and will be terminated."
            : "\(ListFormatter.localizedString(byJoining: Array(Set(names)).sorted())) "
                + "\(names.count == 1 ? "is" : "are") still running and will be terminated."
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        // The buttons are destructive-first, so make Cancel the escape route
        // rather than relying on button order alone.
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
