import AppKit

/// Pure geometry: how the grid sits inside its window.
///
/// Deliberately not on `ViewController`. These are constants with no actor
/// affinity, and living on a `@MainActor` type made every nonisolated reader
/// a concurrency warning — mapping a mouse point to a cell, for one, which
/// runs off the main actor.
nonisolated enum TerminalLayout {
    /// The grid starts below where the traffic lights sit: the window uses
    /// `.fullSizeContentView` so the background runs the full height with no
    /// seam at the titlebar.
    static let titlebarHeight: CGFloat = 28
    /// Matches the window's own curvature so the glass and the drawable end
    /// on the same arc.
    static let windowCornerRadius: CGFloat = 12
    /// Breathing room between the grid and the window edge. Without it the
    /// left column's glyphs were clipped against the frame.
    /// Padding only. The window's chrome — titlebar, and the tab bar when
    /// the window is tabbed — is measured at runtime from
    /// `contentLayoutRect` and added on top; a fixed 28pt here put the first
    /// row underneath the tab bar as soon as a second tab appeared.
    static let insets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    static var insetWidth: CGFloat { insets.left + insets.right }
    static var insetHeight: CGFloat { insets.top + insets.bottom }

    /// How much of the window's chrome (titlebar, and the tab bar once the
    /// window is tabbed) actually overlaps a pane whose top edge sits
    /// `paneDistanceFromTop` points below the window's own top edge. Zero
    /// once a pane is far enough down that no chrome reaches it — a
    /// bottom-row pane in a split has no titlebar above it (M5), and an
    /// interior pane has neither a titlebar nor a tab bar.
    ///
    /// Shared by `ViewController.topInset` (shifts the grid down) and
    /// `ViewController.updateFocusRingLayout` (shifts the focus ring's top
    /// edge down by the same amount) — the two used to agree only on the
    /// grid, so a top pane's ring drew flush with the pane's frame and the
    /// tab bar painted over its top edge.
    static func chromeOverlap(windowChrome: CGFloat, paneDistanceFromTop: CGFloat) -> CGFloat {
        max(0, windowChrome - paneDistanceFromTop)
    }

    /// Which of a pane's edges are also the window's outer edges, in the
    /// window's own base coordinates (`frame` already converted with
    /// `view.convert(_:to: nil)`). Only a pane on an outer edge may round
    /// that corner to match the window's curve; an interior pane butts
    /// against a divider and must stay square there or the divider junction
    /// shows a false notch.
    ///
    /// Boolean, not `CACornerMask`, because the two callers disagree on
    /// which layer corner is visually "top": `TerminalView`'s hosted layer
    /// is flipped (`MinY` is the top), `ViewController`'s ring is not
    /// (`MaxY` is the top). Each maps these three booleans to its own
    /// layer's corner constants; the touch test itself is shared so the two
    /// cannot silently disagree about where the window's corners are.
    static func exteriorEdges(paneFrameInWindow frame: NSRect, windowSize: NSSize)
        -> (top: Bool, left: Bool, right: Bool)
    {
        (
            top: abs(frame.maxY - windowSize.height) < 1,
            left: abs(frame.minX) < 1,
            right: abs(frame.maxX - windowSize.width) < 1
        )
    }
}
