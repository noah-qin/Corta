import AppKit
import CortaTerminal

/// U12 — installing and updating the scroll-position pill.
///
/// Kept out of `ViewController+Selection.swift` (which owns the scroll
/// *gesture*) and out of `ViewController.swift` (which is already the largest
/// file in the app) because it is one self-contained affordance: it appears
/// when the viewport leaves the bottom, says how far back it is or that new
/// output has arrived, and puts the viewport back when clicked.
extension ViewController {
    /// Shows, hides or re-labels the pill to match the viewport.
    ///
    /// Cheap enough to call from `scrollOffset`'s `didSet` and from the frame
    /// path: it touches no grid and allocates only when the text changes.
    func updateScrollPositionIndicator() {
        guard isOperable, let terminalView else {
            scrollPositionIndicator?.removeFromSuperview()
            scrollPositionIndicator = nil
            return
        }
        guard scrollOffset > 0 else {
            scrollPositionIndicator?.removeFromSuperview()
            scrollPositionIndicator = nil
            return
        }
        let indicator = scrollPositionIndicator ?? installScrollPositionIndicator(on: terminalView)
        indicator.update(linesBack: scrollOffset, hasNewOutput: sawOutputWhileScrolled)
    }

    private func installScrollPositionIndicator(on terminalView: TerminalView)
        -> ScrollPositionIndicator
    {
        let indicator = ScrollPositionIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.onReturnToBottom = { [weak self] in self?.returnToBottom() }
        terminalView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(
                equalTo: terminalView.trailingAnchor, constant: -12),
            indicator.bottomAnchor.constraint(
                equalTo: terminalView.bottomAnchor, constant: -10),
        ])
        scrollPositionIndicator = indicator
        return indicator
    }

    /// The return-to-bottom affordance, reachable three ways: the pill, the
    /// Scroll to Bottom command, and — because a person who has scrolled up
    /// and starts typing means to be at the prompt — the next keystroke
    /// (`ViewController+Input`'s existing behaviour, unchanged).
    func returnToBottom() {
        scroll(.toBottom)
    }
}
