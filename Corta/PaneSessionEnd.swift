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
import CortaPOSIX
import CortaTerminal

/// What `PaneSessionEnd` needs from its pane.
protocol PaneSessionEndHost: AnyObject {
    /// The pane's own view; the bar is its subview.
    var view: NSView { get }
    /// The top of the grid, below any window chrome over the pane.
    var topInset: CGFloat { get }
    var didTeardown: Bool { get }
    /// The grid now, or nil without a session.
    func snapshot() -> Grid?
    /// Closes this pane, or its window when it is the last pane — as ⌘W
    /// would, without the confirmation: the session is already over.
    func closeEndedPane()
    func invalidateDisplay()
    func rebuildPane(strictRespawn: Bool)
}

/// The pane's session having ended: the bar that says so until something
/// changes it, and the new session it offers. Only the session's own child
/// ending gets here — a program inside the shell exiting back to its prompt
/// is not the session ending.
final class PaneSessionEnd {
    private weak var host: PaneSessionEndHost?
    private(set) var bar: SessionEndedBar?

    init(host: PaneSessionEndHost) {
        self.host = host
    }

    func present(_ exit: ProcessExit, isConnection: Bool) {
        guard let host else { return }
        bar?.removeFromSuperview()
        let bar = SessionEndedBar(exit: exit, isConnection: isConnection)
        bar.onNewSession = { [weak self] in self?.confirmNewSession(isConnection: isConnection) }
        bar.onClosePane = { [weak host] in host?.closeEndedPane() }
        // On the edge away from the last output: the cursor's half of the
        // screen is where the program left off.
        let cursorInLowerHalf = host.snapshot().map { $0.cursor.row >= $0.rows / 2 } ?? true
        bar.present(
            in: host.view, atTop: cursorInLowerHalf,
            inset: cursorInLowerHalf ? host.topInset : TerminalLayout.insets.bottom)
        self.bar = bar
        // No caret: nothing typed here goes anywhere.
        host.invalidateDisplay()
    }

    func dismiss() {
        bar?.removeFromSuperview()
        bar = nil
    }

    /// A new session replaces this pane's output; asked first, because the
    /// output above is gone afterwards and the old program does not return.
    private func confirmNewSession(isConnection: Bool) {
        let alert = NSAlert()
        alert.messageText = L10n.text("session.ended.confirm.title")
        alert.informativeText = L10n.text(
            isConnection ? "session.ended.confirm.remoteMessage" : "session.ended.confirm.message")
        alert.addButton(withTitle: L10n.text("session.ended.confirm.start"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        alert.present(for: host?.view.window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let host = self.host, !host.didTeardown,
                self.bar != nil
            else { return }
            host.rebuildPane(strictRespawn: isConnection)
        }
    }
}
