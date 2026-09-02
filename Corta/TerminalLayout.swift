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
    static let insets = NSEdgeInsets(
        top: 8 + titlebarHeight, left: 10, bottom: 8, right: 10)
    static var insetWidth: CGFloat { insets.left + insets.right }
    static var insetHeight: CGFloat { insets.top + insets.bottom }
}
