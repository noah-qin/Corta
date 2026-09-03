import Cocoa
import CortaTerminal

/// M6.1, M6.2 and M6.13, pane side: following the config file while running.
///
/// A pane pulls rather than being pushed to — it reads the store when it
/// loads and re-reads it on a change — so a pane created at any point in the
/// app's life is already correct and nothing has to keep a registry of panes
/// to notify.
///
/// Two notifications, not one, because they answer different questions.
/// `ConfigurationStore.didChange` means the file changed: the font or the
/// scrollback may be different. `AppearanceController.didChange` means the
/// live colour variant changed, which also happens when macOS toggles Dark
/// Mode without the file changing at all.
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
        // The font size goes through `setFontSize`, which is the same path
        // ⌘+/⌘− takes: it rebuilds the atlas, re-derives the cell box and
        // re-fits the window. A family change has to force that work even
        // when the size did not move, so the family is applied first and the
        // size is re-applied through a nudge when it is unchanged.
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
        setFontSize(min(64, max(8, configuration.fontSize)))
        invalidateDisplay()
    }

    @objc func appearanceChanged() {
        // Every cell's colours are resolved into the instance buffer when its
        // row is built, so a theme change invalidates the whole buffer — the
        // clear colour alone is read fresh each frame. Forcing a frame
        // without also forcing a rebuild redrew the new background behind the
        // old theme's glyph colours, which on a dark-to-light-to-dark round
        // trip left dark text on a dark ground: the terminal looked empty.
        terminalRenderer.invalidate()
        terminalView.layer?.backgroundColor = nil
        invalidateDisplay()
        terminalView.drawNow()
    }
}
