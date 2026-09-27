// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import CoreText
import CortaTerminal

/// Context menu and font sizing.
extension ViewController {
    // MARK: - Context menu

    /// The right-click menu: editing and split actions, with explicit targets
    /// so it also works when shown programmatically.
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
            // With one pane, the close is the window's.
            let hasSplits = splitController.hasMultiplePanes
            item(
                hasSplits ? "Close Pane" : "Close Window",
                #selector(SplitViewController.performClose(_:)), splitController)
        }
        return menu
    }
    /// ⌘= / ⌘- / ⌘0 apply to every pane: they share one cell geometry
    /// (`SplitViewController.setFontSizeForAllPanes`).
    @objc func increaseFontSize(_ sender: Any?) {
        zoomFontSizeForAllPanes(to: fontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        zoomFontSizeForAllPanes(to: fontSize - 1)
    }

    /// Ends the zoom at the config file's current size, as a new window would
    /// open.
    @objc func resetFontSize(_ sender: Any?) {
        let configured = CGFloat(ConfigurationStore.shared.configuration.fontSize)
        applyFontSizeForAllPanes(configured, isZoomed: false)
    }

    /// Pinch zoom, spent one whole point at a time so it lands on ⌘+/⌘−'s
    /// steps: each size is an atlas rebuild.
    func magnify(by magnification: CGFloat) {
        let sizes = Self.fontSizes(
            forMagnification: magnification,
            accumulator: &pinchAccumulator,
            startingAt: fontSize)
        for size in sizes { zoomFontSizeForAllPanes(to: size) }
    }

    /// The pure step accumulator, for tests.
    nonisolated static func fontSizes(
        forMagnification magnification: CGFloat,
        accumulator: inout CGFloat,
        startingAt fontSize: CGFloat
    ) -> [CGFloat] {
        accumulator += magnification
        // Per point: a deliberate pinch resizes, resting fingers don't.
        let step: CGFloat = 0.15
        var current = fontSize
        var sizes: [CGFloat] = []
        while abs(accumulator) >= step {
            let direction: CGFloat = accumulator > 0 ? 1 : -1
            accumulator -= direction * step
            let target = current + direction
            // Don't fill at the clamp, or reversing fires a burst of rebuilds.
            guard target >= 8, target <= 64 else {
                accumulator = 0
                return sizes
            }
            sizes.append(target)
            current = target
        }
        return sizes
    }

    /// The next pinch starts from zero.
    func endMagnification() {
        pinchAccumulator = 0
    }

    /// A per-window size that never touches the config file: writing the
    /// global default would resize every window on the next config change.
    /// `configurationChanged` skips the size while `isFontSizeZoomed`, and
    /// `resetFontSize` ends it. A pane split off a zoomed window opens at the
    /// configured size.
    private func zoomFontSizeForAllPanes(to newSize: CGFloat) {
        applyFontSizeForAllPanes(newSize, isZoomed: true)
    }

    private func applyFontSizeForAllPanes(_ newSize: CGFloat, isZoomed: Bool) {
        if let splitController {
            splitController.setFontSizeForAllPanes(newSize, isZoomed: isZoomed)
        } else {
            setFontSize(newSize)
            isFontSizeZoomed = isZoomed
        }
    }

    /// A new backing scale needs a new atlas, or text goes soft; the cell box
    /// snaps to device pixels, so this uses the `setFont` path and refits.
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

    /// Re-points the renderer at a new size. One pane keeps its grid and
    /// resizes the window; with splits the grids refit instead.
    func setFontSize(_ newSize: CGFloat) {
        // A failed pane has no renderer; its retry builds one at the
        // configured size.
        guard let terminalRenderer else { return }
        // Below ~8pt the cell degenerates; above 64pt it outgrows the minimum
        // window.
        let clamped = min(64, max(8, newSize))
        guard clamped != fontSize else { return }
        fontSize = clamped

        let font = TerminalFont.primary(
            ofSize: fontSize, family: fontFamily)
        let scale = view.window?.backingScaleFactor ?? terminalRenderer.scale
        // Re-point rather than rebuild; rebuilding made key repeat stutter.
        terminalRenderer.setFont(font, scale: scale)
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)

        // Before the window exists, initial sizing reads the new metrics.
        guard didSizeWindow, let window = view.window else { return }
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        // With splits no window size keeps every grid; the caller refits.
        guard splitController?.hasMultiplePanes != true else {
            invalidateDisplay()
            return
        }
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + verticalInsets)
        // Keep the child's rows × columns and resize the window around it.
        guard let gridSize = lastRequestedSize else { return }
        // Grow from the top-left as Terminal.app does, keeping the text still,
        // clamped to the screen.
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(
            width: CGFloat(gridSize.columns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(gridSize.rows) * metrics.cellHeight + verticalInsets))
        var frame = window.frame
        frame.origin.y = topLeft.y - frame.height
        frame.origin.x = topLeft.x
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
        invalidateDisplay()
    }
}
