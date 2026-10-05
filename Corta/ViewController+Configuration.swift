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
            let metrics = terminalRenderer.pointMetrics
            terminalView.cellSize = CGSize(
                width: metrics.cellWidth, height: metrics.cellHeight)
            view.window?.contentResizeIncrements = NSSize(
                width: metrics.cellWidth, height: metrics.cellHeight)
            if didSizeWindow, let window = view.window, splitController?.hasMultiplePanes != true {
                fitWindowToWholeCells(window, metrics: metrics)
            }
            resizeSessionToFitView(coalesce: false)
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
        let metrics = terminalRenderer.pointMetrics
        terminalView.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        view.window?.contentResizeIncrements = NSSize(
            width: metrics.cellWidth, height: metrics.cellHeight)
        resizeSessionToFitView(coalesce: false)
        invalidateDisplay()
    }

    /// Re-points the renderer while keeping the window where it is: a lone
    /// pane's window moves by less than a cell (`fitWindowToWholeCells`). All font
    /// changes refit the grid, including settings and temporary zoom.
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
            resizeSessionToFitView(coalesce: false)
            invalidateDisplay()
            return
        }
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + verticalInsets + (splitController?.statusBarHeight ?? 0))
        fitWindowToWholeCells(window, metrics: metrics)
        resizeSessionToFitView(coalesce: false)
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
    /// the frame it began with. Full screen and a maximised window keep
    /// their frame; there the remainder stays.
    func fitWindowToWholeCells(_ window: NSWindow, metrics: CellMetrics) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
            metrics.cellWidth > 0, metrics.cellHeight > 0
        else {
            fontChangeAnchor = nil
            return
        }
        view.layoutSubtreeIfNeeded()
        let usable = CGSize(
            width: view.bounds.width - TerminalLayout.insetWidth,
            height: view.bounds.height - verticalInsets)
        let anchor =
            fontChangeAnchor.flatMap { $0.frameSize == window.frame.size ? $0.usable : nil }
            ?? usable
        var columns = max(CGFloat(minimumColumns), (anchor.width / metrics.cellWidth).rounded())
        var rows = max(CGFloat(minimumRows), (anchor.height / metrics.cellHeight).rounded())
        var frame = window.frame
        func resized() -> NSRect {
            var resized = frame
            resized.size.width += columns * metrics.cellWidth - usable.width
            resized.size.height += rows * metrics.cellHeight - usable.height
            // The top edge stays put; AppKit's origin is the bottom left.
            resized.origin.y = frame.maxY - resized.height
            return resized
        }
        // Rounding up may not fit on the screen; give back a cell instead.
        if let visible = window.screen?.visibleFrame {
            while resized().width > visible.width, columns > CGFloat(minimumColumns) { columns -= 1 }
            while resized().height > visible.height, rows > CGFloat(minimumRows) { rows -= 1 }
            frame = resized()
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
        } else {
            frame = resized()
        }
        if frame != window.frame {
            window.setFrame(frame, display: false)
            // The pane's bounds follow on the next layout pass; take it now,
            // so the size sent to the child is the fitted one.
            window.contentView?.layoutSubtreeIfNeeded()
        }
        fontChangeAnchor = (anchor, window.frame.size)
    }
}
