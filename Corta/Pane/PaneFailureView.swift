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

/// What a pane shows when it can't build — no Metal device, no atlas, no
/// child (a moved `$SHELL`, an unmounted directory) — or stops working: the
/// pane's `PaneStatusPanel`, over the window background before anything
/// ran, or over the dimmed last output after. A sentence, not a crash, and
/// only the actions that help: Settings… only where a setting is the cause.
@MainActor
final class PaneFailureView: NSView {
    /// Build again (the shell reinstalled, the volume remounted).
    var onRetry: (() -> Void)?
    /// Re-runs the remote command as a new connection; never falls back to a
    /// local shell.
    var onReconnect: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// Where keyboard focus lands: the rightmost — primary — action. With no
    /// terminal view, focus would otherwise fall to the window.
    private(set) var primaryAction: NSButton?
    let overlay: PaneStatusOverlay

    var announcement: String { accessibilityLabel() ?? "" }

    /// - Parameters:
    ///   - detail: the plain sentence.
    ///   - details: the raw reason, behind Details.
    ///   - note: what the primary action does; by default, Reconnect's.
    ///   - showsSettings: a setting could be the cause (startup failures).
    ///   - backdrop: `.dim` when the last output is still behind it.
    init(
        title: String, detail: String, canRetry: Bool, canReconnect: Bool = false,
        details: String? = nil, note: String? = nil, showsSettings: Bool = true,
        backdrop: PaneStatusOverlay.Backdrop = .opaque,
        symbol: String = "exclamationmark.triangle", tint: NSColor = .systemOrange
    ) {
        // Set once the view exists; the panel's actions reach it through this.
        let relay = Relay()
        var actions: [PaneStatusPanel.Action] = []
        if showsSettings {
            actions.append(.init(title: L10n.text("failure.button.settings")) { relay.view?.onOpenSettings?() })
        }
        if canReconnect {
            actions.append(.init(title: L10n.text("failure.button.reconnect"), isPrimary: !canRetry) {
                relay.view?.onReconnect?()
            })
        }
        if canRetry {
            actions.append(.init(title: L10n.text("failure.button.retry"), isPrimary: true) {
                relay.view?.onRetry?()
            })
        }
        // With Reconnect, say it is a new connection, never the old session.
        let note = note ?? (canReconnect ? L10n.text("failure.reconnectHint") : nil)
        let panel = PaneStatusPanel(
            .init(symbol: symbol, tint: tint, title: title, body: detail, note: note, details: details),
            actions: actions)
        overlay = PaneStatusOverlay(panel: panel, backdrop: backdrop)
        super.init(frame: .zero)
        relay.view = self
        overlay.present(in: self, placement: .center)
        // The rightmost button is the one the panel is about.
        primaryAction = panel.buttons.last
        // Return activates it, so the panel answers the key a person presses
        // without looking.
        primaryAction?.keyEquivalent = "\r"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(panel.accessibilityLabel())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private final class Relay {
        weak var view: PaneFailureView?
    }

    /// Covers `view`, takes the keyboard — or nothing is focused and
    /// assistive technology hears nothing — and is announced.
    func present(in view: NSView, takesFocus: Bool = true) {
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topAnchor.constraint(equalTo: view.topAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if takesFocus {
            view.window?.makeFirstResponder(primaryAction)
        } else {
            // A failed background pane must not consume another pane's Return.
            primaryAction?.keyEquivalent = ""
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    /// Over the dimmed output, a click outside the panel goes to the
    /// terminal, as the overlay's own rule says.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
