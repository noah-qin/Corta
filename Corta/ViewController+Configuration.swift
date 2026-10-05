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

/// Following the config file while running. Panes pull, reading the store
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
}
