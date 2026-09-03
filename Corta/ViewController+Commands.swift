import Cocoa
import CoreText
import CortaTerminal

/// Menu and keyboard-shortcut actions (Track D): font sizing. New-window
/// (⌘N) is app-level and lives in `AppDelegate.newDocument(_:)`.
extension ViewController {
    // MARK: - Context menu

    /// The pane's right-click menu: the editing actions that already exist,
    /// plus the split actions (M5). Targets are set explicitly rather than
    /// left to the responder chain — a context menu's chain starts at the
    /// view the click landed on, which is exactly right, but explicit
    /// targets make the menu work the same when shown programmatically.
    func contextMenu(for terminalView: TerminalView) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ target: AnyObject?, enabled: Bool = true) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = target
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        item("Copy", #selector(copy(_:)), self, enabled: selection != nil)
        item("Paste", #selector(paste(_:)), self)
        item("Select All", #selector(selectAll(_:)), self)
        if let splitController {
            menu.addItem(.separator())
            item("Split Pane Right", #selector(SplitViewController.splitRight(_:)), splitController)
            item("Split Pane Down", #selector(SplitViewController.splitDown(_:)), splitController)
            // With one pane the close is the window's — name it honestly.
            let hasSplits = splitController.hasMultiplePanes
            item(
                hasSplits ? "Close Pane" : "Close Window",
                #selector(SplitViewController.performClose(_:)), splitController)
        }
        return menu
    }
    /// ⌘= / ⌘- / ⌘0 apply to every pane of the window: the window's resize
    /// increments and minimum size derive from one cell geometry, so the
    /// panes share it (`SplitViewController.setFontSizeForAllPanes`).
    @objc func increaseFontSize(_ sender: Any?) {
        setFontSizeForAllPanes(fontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        setFontSizeForAllPanes(fontSize - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        setFontSizeForAllPanes(Self.defaultFontSize)
    }

    private func setFontSizeForAllPanes(_ newSize: CGFloat) {
        if let splitController {
            splitController.setFontSizeForAllPanes(newSize)
        } else {
            setFontSize(newSize)
        }
    }

    /// A font change rebuilds the renderer: the glyph atlas is rasterised
    /// for one size and scale, so there is nothing cheaper (`CONFORMANCE.md`
    /// §2.2, runtime font scaling). With one pane the window follows the new
    /// metrics — content size, resize increments and minimum size all derive
    /// from the cell — keeping the grid's row/column count unchanged; with
    /// splits the pane frames belong to the tree, and the grid re-fits
    /// instead (`SplitViewController.setFontSizeForAllPanes`).
    func setFontSize(_ newSize: CGFloat) {
        // A clamp, not a policy: below ~8pt the primary font's metrics round
        // to a degenerate cell, above 64pt a cell is wider than the minimum
        // window can meaningfully show.
        let clamped = min(64, max(8, newSize))
        guard clamped != fontSize else { return }
        fontSize = clamped

        let font = TerminalFont.primary(ofSize: fontSize)
        let scale = view.window?.backingScaleFactor ?? terminalRenderer.scale
        // Re-point the existing renderer rather than building a new one: the
        // pipelines and the atlas texture are reusable, and rebuilding them
        // per keystroke is what made key repeat stutter.
        terminalRenderer.setFont(font, scale: scale)
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)

        // Before the window exists the initial sizing in `viewDidLoad` /
        // `viewWillAppear` reads the new renderer's metrics directly.
        guard didSizeWindow, let window = view.window else { return }
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        // The window re-fit keeps one pane's grid intact; with splits there
        // is no window size that does that for every pane, and the pane
        // frames are the tree's besides — the caller refits the grids.
        guard splitController?.hasMultiplePanes != true else {
            invalidateDisplay()
            return
        }
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + verticalInsets)
        // Keep the grid the child sees (rows x columns) and resize the
        // window around it; `viewDidLayout` then finds the session already
        // matches and sends no resize. `lastRequestedSize` is set in
        // `viewDidLoad`, so it is non-nil whenever `didSizeWindow` holds.
        guard let gridSize = lastRequestedSize else { return }
        window.setContentSize(NSSize(
            width: CGFloat(gridSize.columns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(gridSize.rows) * metrics.cellHeight + verticalInsets))
        invalidateDisplay()
    }
}
