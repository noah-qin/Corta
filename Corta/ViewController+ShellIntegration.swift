import Cocoa
import CortaTerminal

/// M7.2, app side: the three things OSC 133 marks make possible.
///
/// Jumping between commands and the keyboard scroll actions are here because
/// both are viewport moves expressed in document rows; the clipboard drain is
/// here because OSC 52 arrives through the same output path and, like the
/// marks, is something the child told us rather than something we guessed.
extension ViewController {
    // MARK: - Scrolling from the keyboard

    @objc func scrollHistoryPageUp(_ sender: Any?) { scroll(.page(up: true)) }
    @objc func scrollHistoryPageDown(_ sender: Any?) { scroll(.page(up: false)) }
    @objc func scrollHistoryToTop(_ sender: Any?) { scroll(.toTop) }
    @objc func scrollHistoryToBottom(_ sender: Any?) { scroll(.toBottom) }

    // MARK: - Command to command

    @objc func jumpToPreviousCommand(_ sender: Any?) { jumpToCommand(backwards: true) }
    @objc func jumpToNextCommand(_ sender: Any?) { jumpToCommand(backwards: false) }

    /// Scrolls so the nearest prompt in `backwards`'s direction sits at the
    /// top of the viewport.
    ///
    /// Prompts are addressed by absolute row (`Grid.absoluteRow`), which is
    /// what makes this work across the scrollback boundary without a special
    /// case: the same arithmetic finds a prompt fifty thousand lines back and
    /// one still on screen.
    private func jumpToCommand(backwards: Bool) {
        guard session != nil else { return }
        let grid = session.snapshot()
        let prompts = grid.promptRows
        guard !prompts.isEmpty else {
            // No marks at all: the shell has no integration configured, and
            // pretending otherwise by jumping somewhere arbitrary would be
            // worse than doing nothing.
            NSSound.beep()
            return
        }
        let viewportTop = grid.scrollback.totalPushed - scrollOffset
        let target =
            backwards
            ? prompts.last { $0 < viewportTop }
            : prompts.first { $0 > viewportTop }
        guard let target else { return }
        scrollOffset = min(
            max(0, grid.scrollback.totalPushed - target), grid.scrollback.count)
        invalidateDisplay()
    }

    /// Whether the pane can currently jump — used to grey the menu items out
    /// on a shell with no integration rather than leaving them live and
    /// silent.
    var hasShellIntegration: Bool {
        session?.hasShellIntegration == true
    }

    // MARK: - OSC 52 (M7.11)

    /// Puts text the child asked to copy onto the pasteboard, if the user
    /// allows it.
    ///
    /// Called once per output batch from the render loop's damage pass, which
    /// is where every other "the child told us something" hand-off already
    /// happens. The setting is checked *here* rather than in the core: the
    /// core has no pasteboard and no user, and a policy question belongs with
    /// the layer that can ask one.
    func drainClipboardRequests() {
        guard let text = session.takeClipboardCopy() else { return }
        guard ConfigurationStore.shared.configuration.allowClipboardWrite else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
