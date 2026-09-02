import Cocoa
import CoreText
import CortaTerminal

/// Menu and keyboard-shortcut actions (Track D): font sizing. New-window
/// (⌘N) is app-level and lives in `AppDelegate.newDocument(_:)`.
extension ViewController {
    /// A font change rebuilds the renderer: the glyph atlas is rasterised
    /// for one size and scale, so there is nothing cheaper (`CONFORMANCE.md`
    /// §2.2, runtime font scaling). The window follows the new metrics —
    /// content size, resize increments and minimum size all derive from the
    /// cell — keeping the grid's row/column count unchanged.
    @objc func increaseFontSize(_ sender: Any?) {
        setFontSize(fontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        setFontSize(fontSize - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        setFontSize(Self.defaultFontSize)
    }

    func setFontSize(_ newSize: CGFloat) {
        // A clamp, not a policy: below ~8pt Menlo's metrics round to a
        // degenerate cell, above 64pt a cell is wider than the minimum
        // window can meaningfully show.
        let clamped = min(64, max(8, newSize))
        guard clamped != fontSize else { return }
        fontSize = clamped

        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let scale = view.window?.backingScaleFactor ?? terminalRenderer.scale
        terminalRenderer = try! TerminalRenderer(device: device, font: font, scale: scale)
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)

        // Before the window exists the initial sizing in `viewDidLoad` /
        // `viewWillAppear` reads the new renderer's metrics directly.
        guard didSizeWindow, let window = view.window else { return }
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + Self.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + Self.insetHeight)
        // Keep the grid the child sees (rows x columns) and resize the
        // window around it; `viewDidLayout` then finds the session already
        // matches and sends no resize. `lastRequestedSize` is set in
        // `viewDidLoad`, so it is non-nil whenever `didSizeWindow` holds.
        guard let gridSize = lastRequestedSize else { return }
        window.setContentSize(NSSize(
            width: CGFloat(gridSize.columns) * metrics.cellWidth + Self.insetWidth,
            height: CGFloat(gridSize.rows) * metrics.cellHeight + Self.insetHeight))
        invalidateDisplay()
    }
}
