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

/// What `PaneSessionEnd` needs from its pane.
protocol PaneSessionEndHost: AnyObject {
    /// The pane's own view; the panel is its subview.
    var view: NSView { get }
    var didTeardown: Bool { get }
    /// Closes this pane, or its window when it is the last pane — as ⌘W
    /// would, without the confirmation: the session is already over.
    func closeEndedPane()
    func invalidateDisplay()
    func rebuildPane(strictRespawn: Bool)
}

/// The pane's session having ended: the panel that says so until something
/// changes it, and the new session it offers. Only the session's own child
/// ending gets here — a program inside the shell exiting back to its prompt
/// is not the session ending.
final class PaneSessionEnd {
    private weak var host: PaneSessionEndHost?
    private(set) var overlay: PaneStatusOverlay?

    init(host: PaneSessionEndHost) {
        self.host = host
    }

    /// - Parameters:
    ///   - exit: the session child's final status or signal.
    ///   - isConnection: whether this pane ran a remote launcher.
    ///   - remoteHost: where a connection went, for the title.
    ///   - program: the launcher or shell's name.
    func present(_ exit: ProcessExit, isConnection: Bool, remoteHost: String?, program: String) {
        guard let host else { return }
        overlay?.removeFromSuperview()
        let content = SessionEnded.content(
            for: exit, isConnection: isConnection, host: remoteHost, program: program)
        // Asked nothing more: the panel says what starting again clears. A
        // button press is the decision, never a key — the panel takes no
        // keyboard, so a key pressed in a dead pane starts nothing.
        let panel = PaneStatusPanel(content, actions: [
            .init(title: L10n.text("menu.closePane")) { [weak host] in host?.closeEndedPane() },
            .init(
                title: L10n.text(isConnection ? "failure.button.reconnect" : "session.ended.newSession"),
                isPrimary: true
            ) { [weak self] in self?.startAgain(isConnection: isConnection) },
        ])
        // Found by UI tests and Accessibility as before.
        panel.identifier = NSUserInterfaceItemIdentifier("Corta.SessionEnded")
        let overlay = PaneStatusOverlay(panel: panel, backdrop: .dim)
        // Centred in the pane, as a failure's card is: pinned to the edge
        // away from the last output, it read as misplaced. The dim behind it
        // keeps that output readable.
        overlay.present(in: host.view)
        self.overlay = overlay
        NSAccessibility.post(element: panel, notification: .layoutChanged)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: panel.accessibilityLabel() ?? content.title,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
        // No caret: nothing typed here goes anywhere.
        host.invalidateDisplay()
    }

    func dismiss() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func startAgain(isConnection: Bool) {
        guard let host, !host.didTeardown, overlay != nil else { return }
        host.rebuildPane(strictRespawn: isConnection)
    }
}
