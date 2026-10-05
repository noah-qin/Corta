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
            resizeSessionToFitView()
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
        resizeSessionToFitView()
        invalidateDisplay()
    }

    /// Re-points the renderer while retaining the window frame. All font
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
            resizeSessionToFitView()
            invalidateDisplay()
            return
        }
        window.contentMinSize = NSSize(
            width: CGFloat(minimumColumns) * metrics.cellWidth + TerminalLayout.insetWidth,
            height: CGFloat(minimumRows) * metrics.cellHeight + verticalInsets + (splitController?.statusBarHeight ?? 0))
        resizeSessionToFitView()
        invalidateDisplay()
    }
}
