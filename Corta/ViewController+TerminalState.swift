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

/// Clear Screen, Clear History and Reset Terminal — three names because
/// "clear" means something different everywhere, and the menu says what
/// each discards:
///
/// | Command | Screen | Scrollback | Modes, colours, cursor |
/// | --- | --- | --- | --- |
/// | Clear Screen | erased | kept | kept |
/// | Clear History | kept | discarded | kept |
/// | Reset Terminal | erased | discarded | reset |
///
/// They act on the grid, never the child: `\u{1B}c` written to the
/// child's input would be typed characters (`SECURITY.md` §6). The child is
/// never told, so running jobs are undisturbed; `vim` redraws on its next
/// frame, a shell on ⌃L or Return.
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

    /// Asks before discarding history, which can't be undone — never for Clear
    /// Screen or an empty scrollback, so the dialog keeps its meaning. States
    /// the line count. Honours `confirm-close` rather than a second key.
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

    /// Applies the command, then drops a selection or viewport pointing into
    /// discarded history (which would highlight the wrong text or show
    /// nothing), and confirms with a toast.
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

    /// A failed pane (`PaneFailureView`) has nothing to clear.
    func validateTerminalStateItem(_ item: NSMenuItem) -> Bool { isOperable }
}
