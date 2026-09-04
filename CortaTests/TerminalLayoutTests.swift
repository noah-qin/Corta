import AppKit
import Testing

@testable import Corta

/// Pure geometry, no window and no session: the chrome-overlap and
/// exterior-edge math that `ViewController.topInset`, its focus ring, and
/// `TerminalView`'s drawable corner mask all key off. A regression here is a
/// pane whose text, ring or drawable corner disagrees with where the tab bar
/// actually is — see `ViewController.updateFocusRingLayout`.
struct TerminalLayoutTests {
    /// A pane touching the window's top edge pays for the whole chrome —
    /// the case that used to leave the ring's top edge under the tab bar,
    /// because the ring computed no overlap of its own at all.
    @Test func chromeOverlapIsFullChromeForATopPane() {
        #expect(TerminalLayout.chromeOverlap(windowChrome: 28, paneDistanceFromTop: 0) == 28)
    }

    /// A tab bar appearing grows the chrome; a pane still flush with the
    /// window's top edge must absorb the whole new amount, not just the
    /// titlebar's share — otherwise the grid or the ring only shifts down by
    /// the old (smaller) chrome and the tab bar paints over the difference.
    @Test func chromeOverlapGrowsWithTheChromeItself() {
        // Titlebar alone, then titlebar + tab bar (M4.7's ~40pt).
        #expect(TerminalLayout.chromeOverlap(windowChrome: 28, paneDistanceFromTop: 0) == 28)
        #expect(TerminalLayout.chromeOverlap(windowChrome: 68, paneDistanceFromTop: 0) == 68)
    }

    /// A bottom-row pane in a split has no titlebar above it (M5): its
    /// distance from the window's top already accounts for the whole
    /// chrome, so it owes nothing more.
    @Test func chromeOverlapIsZeroForAPaneBelowTheChrome() {
        #expect(TerminalLayout.chromeOverlap(windowChrome: 68, paneDistanceFromTop: 68) == 0)
        #expect(TerminalLayout.chromeOverlap(windowChrome: 68, paneDistanceFromTop: 200) == 0)
    }

    /// Never negative: a pane can be at most exactly as far down as the
    /// chrome is tall, never further "credited" for it.
    @Test func chromeOverlapNeverGoesNegative() {
        #expect(TerminalLayout.chromeOverlap(windowChrome: 28, paneDistanceFromTop: 500) == 0)
    }

    /// A single pane filling the whole window touches all three edges the
    /// touch test looks at.
    @Test func exteriorEdgesForAFullWindowPane() {
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: NSRect(x: 0, y: 0, width: 800, height: 600),
            windowSize: NSSize(width: 800, height: 600))
        #expect(edges.top)
        #expect(edges.left)
        #expect(edges.right)
    }

    /// The right half of a left/right split touches the window's top and
    /// right edges, but not its left — the divider sits there instead, and
    /// that corner must stay square (see `TerminalView.commonInit`).
    @Test func exteriorEdgesForTheRightPaneOfAColumnSplit() {
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: NSRect(x: 400, y: 0, width: 400, height: 600),
            windowSize: NSSize(width: 800, height: 600))
        #expect(edges.top)
        #expect(!edges.left)
        #expect(edges.right)
    }

    /// The bottom-right pane of a 2×2 split does not touch the window's top
    /// or left edge — the two edges its own top-left corner sits against are
    /// dividers, not the window frame, and that corner must render square or
    /// the four panes' shared center shows a false rounded notch.
    @Test func exteriorEdgesForABottomRightPaneOfA2x2Split() {
        let edges = TerminalLayout.exteriorEdges(
            paneFrameInWindow: NSRect(x: 400, y: 0, width: 400, height: 300),
            windowSize: NSSize(width: 800, height: 600))
        #expect(!edges.top)
        #expect(!edges.left)
        #expect(edges.right)
    }
}
