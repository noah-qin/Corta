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

/// What a pane shows when it can't build: no Metal device, no atlas, or no
/// child (a moved `$SHELL`, an unmounted directory). A sentence, not a
/// crash. Plain by design: icon, sentence, error, and the actions that
/// help — failure shown by symbol and words, never colour alone.
@MainActor
final class PaneFailureView: NSView {
    /// Build again (the shell reinstalled, the volume remounted).
    var onRetry: (() -> Void)?
    /// Re-runs the remote command as a new connection; never falls back to a
    /// local shell.
    var onReconnect: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// Where keyboard focus lands: Try Again, else Settings. With no terminal
    /// view, focus would otherwise fall to the window.
    private(set) var primaryAction: NSButton?

    var announcement: String { accessibilityLabel() ?? "" }

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

    init(title: String, detail: String, canRetry: Bool, canReconnect: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        // The shape carries the meaning; label colour survives Increase
        // Contrast.
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityLabel(title)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3

        // With Reconnect, say it is a new connection, never the old session.
        let detailText =
            canReconnect
            ? "\(detail)\n\n\(L10n.text("failure.reconnectHint"))"
            : detail
        let detailLabel = NSTextField(wrappingLabelWithString: detailText)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.isSelectable = true

        var buttons: [NSView] = []
        if canRetry {
            let retry = NSButton(
                title: L10n.text("failure.button.retry"), target: self,
                action: #selector(retryTapped))
            retry.keyEquivalent = "\r"
            buttons.append(retry)
            primaryAction = retry
        }
        if canReconnect {
            let reconnect = NSButton(
                title: L10n.text("failure.button.reconnect"), target: self,
                action: #selector(reconnectTapped))
            buttons.append(reconnect)
            if primaryAction == nil { primaryAction = reconnect }
        }
        let settings = NSButton(
            title: L10n.text("failure.button.settings"), target: self,
            action: #selector(settingsTapped))
        buttons.append(settings)
        if primaryAction == nil { primaryAction = settings }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [icon, titleLabel, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        // One described group, not four elements read in layout order.
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detailText)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @objc private func retryTapped() { onRetry?() }
    @objc private func reconnectTapped() { onReconnect?() }
    @objc private func settingsTapped() { onOpenSettings?() }
}
