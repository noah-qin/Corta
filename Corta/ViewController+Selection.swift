import Cocoa
import CortaTerminal

/// Selection and the viewport it is anchored to (Track C): scrolling, and
/// the mouse-mode query the view's mouse handlers consult.
extension ViewController {
    /// The core's ?1006 SGR mouse-reporting flag (M2.7). While off, clicks
    /// and the wheel keep their normal terminal behaviour.
    func mouseReportingEnabled() -> Bool {
        session.isSgrMouseEncodingEnabled
    }

    func scroll(_ gesture: ScrollGesture) {

        let historyDepth = session.snapshot().scrollback.count
        switch gesture {
        case .lines(let delta):
            scrollOffset = min(max(0, scrollOffset + delta), historyDepth)
        case .page(let up):
            let usableHeight = view.bounds.height - Self.insetHeight
            let rows = Int(usableHeight / terminalRenderer.pointMetrics.cellHeight)
            scrollOffset = min(max(0, scrollOffset + (up ? rows : -rows)), historyDepth)
        case .toTop:
            scrollOffset = historyDepth
        case .toBottom:
            scrollOffset = 0
        }
        // Scrolling moves the viewport without any grid output, so the
        // output flag alone would never trigger the redraw.
        invalidateDisplay()
    }
}
