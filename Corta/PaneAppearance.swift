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

import AppKit
import CortaTerminal

/// What following the configuration and appearance needs from the pane.
protocol PaneAppearanceHost: AnyObject {
    var view: NSView { get }
    var session: TerminalSession! { get }
    var terminalView: TerminalView! { get }
    var terminalRenderer: TerminalRenderer! { get }
    var splitController: SplitViewController? { get }
    var didSizeWindow: Bool { get }
    /// A change rebuilds the atlas, rasterised for one size.
    var fontSize: CGFloat { get set }
    /// `Configuration.systemFontFamily` means System Monospaced.
    var fontFamily: String { get set }
    /// A temporary zoom, which a configuration change leaves alone.
    var isFontSizeZoomed: Bool { get }
    func resizeSessionToFitView(coalesce: Bool)
    func invalidateDisplay()
}

/// Following the config file while running, and re-pointing the renderer
/// when the font size or backing scale changes. Each pane pulls, reading the store
/// at load and on change, so no registry is needed. Two notifications:
/// `ConfigurationStore.didChange` (the file changed) and
/// `AppearanceController.didChange` (the live variant changed, e.g. Dark
/// Mode, with no file change).
final class PaneAppearance: NSObject {
    weak var host: PaneAppearanceHost?
    private var isObserving = false

    init(host: PaneAppearanceHost? = nil) {
        self.host = host
    }

    // The pane's state, read and written where the code that uses it reads
    // it best.
    private var session: TerminalSession? { host?.session ?? nil }
    private var terminalView: TerminalView? { host?.terminalView ?? nil }
    private var terminalRenderer: TerminalRenderer? { host?.terminalRenderer ?? nil }
    private var fontSize: CGFloat {
        get { host?.fontSize ?? ViewController.defaultFontSize }
        set { host?.fontSize = newValue }
    }
    private var fontFamily: String {
        get { host?.fontFamily ?? Configuration.systemFontFamily }
        set { host?.fontFamily = newValue }
    }
    private var isFontSizeZoomed: Bool { host?.isFontSizeZoomed ?? false }
    private func invalidateDisplay() { host?.invalidateDisplay() }

    func observe() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: ConfigurationStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: AppearanceController.didChange, object: nil)
    }

    /// The pane closed.
    func stop() {
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }

    @objc func configurationChanged() {
        let configuration = ConfigurationStore.shared.configuration
        terminalView?.mouseOverrideModifier = configuration.mouseOverrideModifier
        // A zoom survives config changes; `resetFontSize` ends it. Family
        // and size apply together, so a reload that changes both re-points
        // the renderer, fits the window and resizes the child once.
        let size = isFontSizeZoomed ? fontSize : min(64, max(8, configuration.fontSize))
        if configuration.fontFamily != fontFamily || size != fontSize {
            fontFamily = configuration.fontFamily
            applyFont(size: size, settle: true)
        }
        invalidateDisplay()
    }

    @objc func appearanceChanged() {
        guard let host else { return }
        (host.view.window?.windowController as? TerminalWindowController)?.applyCanvasAppearance()
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
        terminalRenderer?.invalidate()
        terminalView?.layer?.backgroundColor = nil
        invalidateDisplay()
        terminalView?.drawNow()
    }

    // MARK: - Font size

    /// A new backing scale needs a new atlas, or text goes soft; the cell box
    /// snaps to device pixels, so this uses the `setFont` path and refits.
    /// The window is not fitted: moving between displays is not a font
    /// change, and a frame that changed under a drag would fight it.
    func rebuildAtlas(forBackingScale scale: CGFloat) {
        guard let terminalRenderer, scale > 0, scale != terminalRenderer.scale else { return }
        terminalRenderer.setFont(
            TerminalFont.primary(
                ofSize: fontSize,
                family: fontFamily),
            scale: scale)
        applyCellMetrics(settle: true, fitsWindow: false)
    }

    /// Re-points the renderer while keeping the window where it is: a lone
    /// pane's window moves its bottom and right edges to whole cells
    /// (`SplitViewController.fitWindowToWholeCells`). All font changes refit
    /// the grid, including settings and temporary zoom.
    ///
    /// `settle: false` is a step of a gesture still in progress — a pinch
    /// steps a point at a time, several a second — so the grid refits through
    /// the drag debounce and the window waits for `settleFontChange()`.
    func setFontSize(_ newSize: CGFloat, settle: Bool = true) {
        let clamped = min(64, max(8, newSize))
        guard clamped != fontSize else { return }
        applyFont(size: clamped, settle: settle)
    }

    /// The end of a gesture's run of `setFontSize(_:settle: false)`.
    func settleFontChange() {
        guard terminalRenderer != nil else { return }
        applyCellMetrics(settle: true, fitsWindow: true)
    }

    /// Re-points the renderer at `size` in the current family — rather than
    /// rebuilding it, which made key repeat stutter — and follows with the
    /// cell metrics. Below ~8pt the cell degenerates; above 64pt it outgrows
    /// the minimum window.
    private func applyFont(size: CGFloat, settle: Bool) {
        fontSize = min(64, max(8, size))
        // A failed pane has no renderer; its retry builds one at the
        // configured size.
        guard let terminalRenderer else { return }
        let scale = host?.view.window?.backingScaleFactor ?? terminalRenderer.scale
        terminalRenderer.setFont(TerminalFont.primary(ofSize: fontSize, family: fontFamily), scale: scale)
        applyCellMetrics(settle: settle, fitsWindow: true)
    }

    /// After the renderer's metrics changed — size, family or backing scale —
    /// everything measured in cells follows: the view's cell box, the
    /// window's resize increments and minimum, the window fitted to whole
    /// cells (`fitsWindow`, and only once a change settles), then the grid.
    /// One path, so no source of a metrics change skips a step.
    private func applyCellMetrics(settle: Bool, fitsWindow: Bool) {
        guard let host, let terminalRenderer else { return }
        let metrics = terminalRenderer.pointMetrics
        terminalView?.cellSize = CGSize(width: metrics.cellWidth, height: metrics.cellHeight)
        // Before the window exists, initial sizing reads the new metrics.
        guard host.didSizeWindow, let window = host.view.window else {
            invalidateDisplay()
            return
        }
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        host.splitController?.updateWindowMinSize()
        if settle, fitsWindow { host.splitController?.fitWindowToWholeCells(metrics: metrics) }
        host.resizeSessionToFitView(coalesce: !settle)
        invalidateDisplay()
    }
}
