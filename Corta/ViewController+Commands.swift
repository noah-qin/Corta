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

    /// M6.14 — the trackpad magnification gesture, driving the same scale
    /// path as ⌘+/⌘−.
    ///
    /// A pinch is continuous and the font size is not: the atlas is
    /// rasterised per size, so a fractional size is a rebuild for a step the
    /// keyboard could not produce anyway. The gesture's magnification is
    /// accumulated instead and spent one whole point at a time, which keeps
    /// a live pinch on exactly the steps ⌘+/⌘− lands on.
    func magnify(by magnification: CGFloat) {
        let sizes = Self.fontSizes(
            forMagnification: magnification,
            accumulator: &pinchAccumulator,
            startingAt: fontSize)
        for size in sizes { setFontSizeForAllPanes(size) }
    }

    /// Pure step accumulator behind the AppKit gesture entry point. Keeping
    /// the continuous-to-discrete conversion here makes its threshold,
    /// direction, multi-step behaviour and clamps deterministic in tests.
    nonisolated static func fontSizes(
        forMagnification magnification: CGFloat,
        accumulator: inout CGFloat,
        startingAt fontSize: CGFloat
    ) -> [CGFloat] {
        accumulator += magnification
        // ~0.15 of a pinch per point: small enough that a deliberate pinch
        // resizes, large enough that resting two fingers does not.
        let step: CGFloat = 0.15
        var current = fontSize
        var sizes: [CGFloat] = []
        while abs(accumulator) >= step {
            let direction: CGFloat = accumulator > 0 ? 1 : -1
            accumulator -= direction * step
            let target = current + direction
            // At the clamp the accumulator would otherwise keep filling and
            // fire a burst of rebuilds the moment the pinch reverses.
            guard target >= 8, target <= 64 else {
                accumulator = 0
                return sizes
            }
            sizes.append(target)
            current = target
        }
        return sizes
    }

    /// Called when the gesture ends, so the next pinch starts from zero
    /// rather than from a leftover fraction of the last one.
    func endMagnification() {
        pinchAccumulator = 0
    }

    private func setFontSizeForAllPanes(_ newSize: CGFloat) {
        if let splitController {
            splitController.setFontSizeForAllPanes(newSize)
        } else {
            setFontSize(newSize)
        }
        persistFontSize(newSize)
    }

    /// Writes the new size to the config file, which is the only store there
    /// is (`CLAUDE.md`: two stores drift, and the file has to win).
    ///
    /// Without this, ⌘+ / ⌘− / pinch changed a size that lived nowhere:
    /// the file still said 12, and the *next* config change of any kind —
    /// picking a theme, opening the settings page, saving the file in an
    /// editor — ran `configurationChanged`, which re-applies `font-size` and
    /// silently threw the zoom away. It also meant a zoom did not survive a
    /// relaunch, and a new window opened at the old size while the one beside
    /// it was zoomed.
    ///
    /// `ConfigurationStore.update` is a no-op when the value is unchanged, so
    /// the write happens once per whole-point step and a pinch that ends
    /// where it started writes nothing at all. `setFontSize` is likewise
    /// guarded, so the change notification this posts costs every pane a
    /// comparison and nothing more.
    private func persistFontSize(_ newSize: CGFloat) {
        let clamped = Double(min(64, max(8, newSize)))
        ConfigurationStore.shared.update { $0.fontSize = clamped }
    }

    /// A font change rebuilds the renderer: the glyph atlas is rasterised
    /// for one size and scale, so there is nothing cheaper (`CONFORMANCE.md`
    /// §2.2, runtime font scaling). With one pane the window follows the new
    /// metrics — content size, resize increments and minimum size all derive
    /// from the cell — keeping the grid's row/column count unchanged; with
    /// splits the pane frames belong to the tree, and the grid re-fits
    /// instead (`SplitViewController.setFontSizeForAllPanes`).
    /// The window moved to a display with a different backing scale. Glyphs
    /// are rasterised at `font size * scale` into an atlas built for one
    /// density (`TerminalRenderer.init`), so the atlas has to be rebuilt or
    /// the text is resampled and goes soft. The cell box is snapped to whole
    /// *device* pixels too, so the grid geometry follows the new scale as
    /// well — that is why this goes through the same `setFont` path a font
    /// change does, and refits the session afterwards.
    func rebuildAtlas(forBackingScale scale: CGFloat) {
        guard scale > 0, scale != terminalRenderer.scale else { return }
        terminalRenderer.setFont(
            TerminalFont.primary(
                ofSize: fontSize,
                family: fontFamily),
            scale: scale)
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        view.window?.contentResizeIncrements = NSSize(
            width: metrics.cellWidth, height: metrics.cellHeight)
        resizeSessionToFitView()
        invalidateDisplay()
    }

    func setFontSize(_ newSize: CGFloat) {
        // A clamp, not a policy: below ~8pt the primary font's metrics round
        // to a degenerate cell, above 64pt a cell is wider than the minimum
        // window can meaningfully show.
        let clamped = min(64, max(8, newSize))
        guard clamped != fontSize else { return }
        fontSize = clamped

        let font = TerminalFont.primary(
            ofSize: fontSize, family: fontFamily)
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
