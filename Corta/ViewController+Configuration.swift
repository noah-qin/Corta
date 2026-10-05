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
import CortaTerminal

/// Following the config file while running, and re-pointing the renderer
/// when the font size or backing scale changes. Panes pull, reading the store
/// at load and on change, so no registry is needed. Two notifications:
/// `ConfigurationStore.didChange` (the file changed) and
/// `AppearanceController.didChange` (the live variant changed, e.g. Dark
/// Mode, with no file change).
extension ViewController {
    func observeConfiguration() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: ConfigurationStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: AppearanceController.didChange, object: nil)
    }

    @objc func configurationChanged() {
        let configuration = ConfigurationStore.shared.configuration
        terminalView?.mouseOverrideModifier = configuration.mouseOverrideModifier
        // A family change forces `setFontSize` (the ⌘+/⌘− path) even at the
        // same size.
        if configuration.fontFamily != fontFamily {
            fontFamily = configuration.fontFamily
            let scale = view.window?.backingScaleFactor ?? terminalRenderer.scale
            terminalRenderer.setFont(
                TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
            applyCellMetrics(settle: true)
        }
        // A zoom survives config changes; `resetFontSize` ends it.
        if !isFontSizeZoomed {
            setFontSize(min(64, max(8, configuration.fontSize)))
        }
        invalidateDisplay()
    }

    @objc func appearanceChanged() {
        (view.window?.windowController as? TerminalWindowController)?.applyCanvasAppearance()
        // OSC 10/11/12 answers follow the live variant.
        session?.dynamicColors =
            AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
            .dynamicColors
        // Only the defaults: an OSC 4'd index is terminal state, and a
        // get-then-set would race the reader thread.
        session?.updateIndexedPaletteDefaults(
            to: AppearanceController.shared.theme.variant(dark: AppearanceController.shared.isDark)
                .indexedPaletteDefaults.defaults)
        // Colours are baked into the instance buffer, so rebuild it all; a
        // forced frame alone kept the old glyph colours (dark on dark).
        terminalRenderer.invalidate()
        terminalView.layer?.backgroundColor = nil
        invalidateDisplay()
        terminalView.drawNow()
    }

    // MARK: - Font size

    /// A new backing scale needs a new atlas, or text goes soft; the cell box
    /// snaps to device pixels, so this uses the `setFont` path and refits.
    func rebuildAtlas(forBackingScale scale: CGFloat) {
        guard scale > 0, scale != terminalRenderer.scale else { return }
        terminalRenderer.setFont(
            TerminalFont.primary(
                ofSize: fontSize,
                family: fontFamily),
            scale: scale)
        applyCellMetrics(settle: true)
    }

    /// Re-points the renderer while keeping the window where it is: a lone
    /// pane's window moves by less than a cell (`fitWindowToWholeCells`). All font
    /// changes refit the grid, including settings and temporary zoom.
    ///
    /// `settle: false` is a step of a gesture still in progress — a pinch
    /// steps a point at a time, several a second — so the grid refits through
    /// the drag debounce and the window waits for `settleFontChange()`.
    func setFontSize(_ newSize: CGFloat, settle: Bool = true) {
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
        applyCellMetrics(settle: settle)
    }

    /// The end of a gesture's run of `setFontSize(_:settle: false)`.
    func settleFontChange() {
        guard terminalRenderer != nil else { return }
        applyCellMetrics(settle: true)
    }

    /// After the renderer's metrics changed — size, family or backing scale —
    /// everything measured in cells follows: the view's cell box, the
    /// window's resize increments and minimum, a lone pane's window fitted to
    /// whole cells, and the grid. One path, so no source of a metrics change
    /// skips a step.
    private func applyCellMetrics(settle: Bool) {
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        // Before the window exists, initial sizing reads the new metrics.
        guard didSizeWindow, let window = view.window else {
            invalidateDisplay()
            return
        }
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        // With splits no window size keeps every grid: each pane refits in
        // the frame it has, and the split controller owns the minimum.
        if splitController?.hasMultiplePanes != true {
            window.contentMinSize = NSSize(
                width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
                height: CGFloat(minimumRows) * metrics.cellHeight + verticalInsets
                    + (splitController?.statusBarHeight ?? 0))
            if settle { fitWindowToWholeCells(window, metrics: metrics) }
        }
        resizeSessionToFitView(coalesce: !settle)
        invalidateDisplay()
    }

    /// Trims or grows a lone pane's window by less than a cell, top edge
    /// fixed, so the new font's grid fills it exactly. Without it the window
    /// kept its frame and the remainder — anywhere from nothing to almost a
    /// row — sat under the last line, different after every step.
    ///
    /// Rounded from the size the run of font changes started at, not from
    /// the last step's: rounding each step from the one before walks the
    /// window a little every time, while from the anchor ⌘+ then ⌘0 lands on
    /// the frame it began with. A frame or a usable area changed by anything
    /// else — a drag, the status bar — starts a new run.
    ///
    /// Left alone, keeping its remainder: full screen and a maximised window,
    /// the Quick Terminal's panel (docked to its screen edge), a window with
    /// native tabs (they share one frame, and the other tabs keep their own
    /// font), and a window that does not fit inside its screen or would not
    /// after a cell given back.
    func fitWindowToWholeCells(_ window: NSWindow, metrics: CellMetrics) {
        fontChangeAnchor = fontChangeAnchor.flatMap { $0.frameSize == window.frame.size ? $0 : nil }
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed, !(window is NSPanel),
            (window.tabbedWindows?.count ?? 1) <= 1,
            metrics.cellWidth > 0, metrics.cellHeight > 0
        else {
            fontChangeAnchor = nil
            return
        }
        view.layoutSubtreeIfNeeded()
        let usable = CGSize(
            width: view.bounds.width - TerminalLayout.insetWidth,
            height: view.bounds.height - verticalInsets)
        if let previous = fontChangeAnchor,
            abs(previous.fittedUsable.width - usable.width) > 0.5
                || abs(previous.fittedUsable.height - usable.height) > 0.5
        {
            fontChangeAnchor = nil
        }
        let anchor = fontChangeAnchor?.usable ?? usable
        var columns = max(CGFloat(minimumColumns), (anchor.width / metrics.cellWidth).rounded())
        var rows = max(CGFloat(minimumRows), (anchor.height / metrics.cellHeight).rounded())
        let current = window.frame
        func fitted() -> NSRect {
            var frame = current
            frame.size.width += columns * metrics.cellWidth - usable.width
            frame.size.height += rows * metrics.cellHeight - usable.height
            // The top edge stays put; AppKit's origin is the bottom left.
            frame.origin.y = current.maxY - frame.height
            return frame
        }
        var frame = fitted()
        if let visible = window.screen?.visibleFrame {
            // Never pull a window that already overhangs its screen back in.
            guard visible.contains(current) else {
                fontChangeAnchor = nil
                return
            }
            // Rounding up may cross the screen's edge; give back one cell.
            if frame.maxX > visible.maxX, columns > CGFloat(minimumColumns) { columns -= 1 }
            if frame.minY < visible.minY, rows > CGFloat(minimumRows) { rows -= 1 }
            frame = fitted()
            guard visible.contains(frame) else {
                fontChangeAnchor = nil
                return
            }
        }
        if frame != current {
            window.setFrame(frame, display: false)
            // The pane's bounds follow on the next layout pass; take it now,
            // so the size sent to the child is the fitted one.
            window.contentView?.layoutSubtreeIfNeeded()
        }
        fontChangeAnchor = (
            usable: anchor, frameSize: window.frame.size,
            fittedUsable: CGSize(
                width: view.bounds.width - TerminalLayout.insetWidth,
                height: view.bounds.height - verticalInsets))
    }
}
