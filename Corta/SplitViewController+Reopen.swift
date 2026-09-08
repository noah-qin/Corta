import AppKit
import CortaTerminal

/// U15 — reopening the arrangement of a pane that was closed.
///
/// **What this restores, and what it does not.** The *arrangement*: a pane
/// back in the position it occupied, split the way it was split, at the
/// divider it had, in the working directory it reported. Not the process, not
/// the scrollback, not the command that was running — a closed child is gone,
/// and a terminal that pretended otherwise would be showing a transcript with
/// a prompt that answers to nothing. That is the same line `SessionRestore`
/// draws for a relaunch, drawn again here for a pane; the command is named
/// "Reopen Closed Pane" rather than "Undo Close" for exactly that reason.
///
/// **Why one, and why not a stack.** The record is a single pane deep. A
/// deeper stack sounds free and is not: the second entry's position is
/// described relative to a tree that the first reopen has already changed, so
/// every entry below the top is a guess that gets worse with each one. One
/// entry is the case that actually happens — closing the wrong pane, and
/// wanting it back immediately.
extension SplitViewController {
    /// Everything needed to put a closed pane back where it was.
    struct ClosedPane {
        /// The directory the pane last reported through OSC 7, or `nil` for
        /// the home directory — the same fallback a fresh pane uses.
        var directory: String?
        /// The pane it shared a split with, weakly: if that one has since
        /// closed too, the position it described no longer exists.
        weak var sibling: ViewController?
        /// How the two were split.
        var orientation: SplitOrientation
        /// Whether the closed pane was the *first* subview of that split —
        /// left or top — so it comes back on its own side rather than the
        /// other one.
        var wasFirst: Bool
        /// The divider fraction the split had, so the sibling does not simply
        /// keep the space it inherited.
        var position: Double
    }

    /// Records where a pane sat, immediately before it is removed from the
    /// tree. Nothing is recorded for the last pane in a window: closing that
    /// closes the window, and the window's own arrangement is
    /// `SessionRestore`'s business.
    func noteClosing(_ pane: ViewController) {
        guard hasMultiplePanes,
            let split = pane.view.superview as? NSSplitView, split.subviews.count == 2,
            let index = split.subviews.firstIndex(of: pane.view)
        else {
            lastClosedPane = nil
            return
        }
        let siblingView = split.subviews[index == 0 ? 1 : 0]
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        let firstExtent =
            split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
        lastClosedPane = ClosedPane(
            directory: pane.session?.workingDirectory,
            sibling: panes.first { $0.view === siblingView || siblingView.isDescendant(of: $0.view) }
                ?? panes.first { $0 !== pane && $0.view.isDescendant(of: siblingView) },
            orientation: split.isVertical ? .columns : .rows,
            wasFirst: index == 0,
            position: axis > 0 ? Double(firstExtent / axis) : 0.5)
    }

    /// Whether there is a closed pane to reopen — read by the menu item, so
    /// it is disabled rather than silent when there is not.
    var canReopenClosedPane: Bool { lastClosedPane?.sibling != nil }

    @objc func reopenClosedPane(_ sender: Any?) {
        guard let record = lastClosedPane, let sibling = record.sibling else {
            // The sibling closed too, so the position the record describes no
            // longer exists. Better to say nothing happened than to open a
            // pane somewhere arbitrary and call it a restore.
            NSSound.beep()
            return
        }
        lastClosedPane = nil
        focusedPane = sibling
        splitFocusedPane(orientation: record.orientation, workingDirectory: record.directory)
        guard let reopened = focusedPane, reopened !== sibling else { return }
        // `splitFocusedPane` always puts the new pane second and halves the
        // split. Both are put back: the pane goes to the side it was on, and
        // the divider to the fraction it had.
        if record.wasFirst, let split = reopened.view.superview as? NSSplitView,
            split.subviews.count == 2
        {
            split.addSubview(reopened.view, positioned: .below, relativeTo: split.subviews[0])
        }
        view.layoutSubtreeIfNeeded()
        if let split = reopened.view.superview as? NSSplitView {
            let axis = split.isVertical ? split.bounds.width : split.bounds.height
            if axis > 0 { split.setPosition(axis * CGFloat(record.position), ofDividerAt: 0) }
        }
        view.layoutSubtreeIfNeeded()
        for pane in panes { pane.resizeSessionToFitView() }
        view.window?.makeFirstResponder(reopened.terminalView)
        noteLayoutChanged()
    }
}
