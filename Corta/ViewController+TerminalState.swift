import AppKit
import CortaTerminal

/// U11 — Clear Screen, Clear History and Reset Terminal.
///
/// **Why three commands and not one.** Every terminal has *something* called
/// "clear", and no two agree on what it throws away: a shell's `clear` erases
/// the screen and, on some systems, scrolls it into the history first;
/// Terminal.app's ⌘K discards the scrollback as well; a `reset` also puts the
/// modes back. Corta names the three separately and says in the menu what
/// each one discards, so nobody has to find out by losing a build log:
///
/// | Command | Screen | Scrollback | Modes, colours, cursor |
/// | --- | --- | --- | --- |
/// | Clear Screen | erased | kept | kept |
/// | Clear History | kept | discarded | kept |
/// | Reset Terminal | erased | discarded | reset |
///
/// **Why they act on the grid and not on the child.** Writing `\u{1B}c` to
/// the child's *input* would deliver it as typed characters — the shell would
/// echo it, and `SECURITY.md` §6 keeps that channel for what the user
/// actually typed. A person asking Corta to clear its own screen is asking
/// Corta, not the program running in it. The child is never told, which is
/// also why none of the three disturbs a running job: `vim` redraws on its
/// next frame, and a shell's prompt is reprinted by ⌃L or the next Return.
extension ViewController {
    @objc func clearScreen(_ sender: Any?) {
        applyTerminalState(.clearScreen, notice: "toast.clearedScreen")
    }

    @objc func clearHistory(_ sender: Any?) {
        guard confirmDiscardingHistory(titleKey: "clear.history.title") else { return }
        applyTerminalState(.clearHistory, notice: "toast.clearedHistory")
    }

    @objc func resetTerminal(_ sender: Any?) {
        guard confirmDiscardingHistory(titleKey: "clear.reset.title") else { return }
        applyTerminalState(.reset, notice: "toast.resetTerminal")
    }

    /// Asks before throwing history away — and only then.
    ///
    /// The two commands that discard the scrollback are not undoable: the
    /// lines are gone, and no amount of shipping them unbound is a mechanism.
    /// Clear Screen keeps the history and is not asked about, and neither is
    /// a pane whose scrollback is empty, because there is nothing to lose and
    /// a dialog with no stakes is a dialog people learn to dismiss unread.
    /// The count is in the question, since "discard 47 lines" and "discard
    /// 90,000 lines" are different decisions.
    ///
    /// Honours `confirm-close`, the existing key for "ask me before I lose
    /// work", rather than adding a second one that means the same thing.
    private func confirmDiscardingHistory(titleKey: String) -> Bool {
        guard isOperable, ConfigurationStore.shared.configuration.confirmClose else { return true }
        let lines = session.snapshot().scrollback.count
        guard lines > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(titleKey)
        alert.informativeText = L10n.format("clear.history.detail", lines)
        alert.addButton(withTitle: L10n.text("clear.history.discard"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Applies the command, then puts the viewport and the selection back
    /// into a state that matches what is now on screen.
    ///
    /// Both of those matter and neither is obvious. A selection is anchored
    /// to document rows, so a selection over history that no longer exists
    /// would highlight whatever slid into those coordinates; and the viewport
    /// can be scrolled back into a scrollback that has just been discarded,
    /// which would leave the pane showing nothing at all. The toast is the
    /// confirmation — these are the commands whose whole effect is that
    /// something is gone, and "did that do anything?" is the question a
    /// silent one leaves behind.
    private func applyTerminalState(
        _ command: TerminalSession.TerminalStateCommand, notice: String
    ) {
        guard isOperable else { return }
        session.apply(command)
        selection = nil
        scrollOffset = 0
        invalidateDisplay()
        terminalView?.noteAccessibilityValueChanged()
        terminalView?.noteAccessibilitySelectionChanged()
        terminalView?.showToast(L10n.text(notice))
    }

    /// Greyed out when the pane has no terminal — a failed pane
    /// (`PaneFailureView`) has nothing to clear, and a menu item that cannot
    /// act should say so rather than doing nothing.
    func validateTerminalStateItem(_ item: NSMenuItem) -> Bool { isOperable }
}
