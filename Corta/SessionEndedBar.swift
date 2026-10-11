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

/// What a pane shows once its session has ended: a bar along one edge that
/// says so, how it ended, and what can be done — start a new session here,
/// or close the pane. A toast said it for two seconds; after that a dead
/// pane looked exactly like a live one that was not answering.
///
/// It is not drawn into the grid and nothing is written to the PTY, so
/// copy, search and export still see only what the program wrote. It sits
/// on the edge away from the last output, so that stays readable.
@MainActor
final class SessionEndedBar: NSView {
    var onNewSession: (() -> Void)?
    var onClosePane: (() -> Void)?

    let message: String
    private(set) var newSessionButton: NSButton!
    private(set) var closeButton: NSButton!

    /// The words for an exit, for the bar and for assistive technology.
    /// Exit code 0 is a normal end, said plainly; nothing here guesses why
    /// a program ended, only how.
    nonisolated static func message(for exit: ChildExit, isConnection: Bool) -> String {
        switch exit {
        case .exited(let code):
            return L10n.format(
                isConnection ? "session.ended.connection.exited" : "session.ended.exited",
                Int(code))
        case .signalled(let signal):
            return L10n.format(
                isConnection ? "session.ended.connection.signalled" : "session.ended.signalled",
                signalName(signal), Int(signal))
        }
    }

    /// `SIGTERM`, `SIGKILL`, …; the number alone for one without a name.
    nonisolated static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
            SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE",
            SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM",
            SIGTERM: "SIGTERM", SIGUSR1: "SIGUSR1", SIGUSR2: "SIGUSR2", SIGXCPU: "SIGXCPU",
        ]
        return names[signal] ?? "signal \(signal)"
    }

    /// - Parameter isConnection: the pane ran a remote launcher; its button
    ///   reconnects, and says so.
    init(exit: ChildExit, isConnection: Bool) {
        message = Self.message(for: exit, isConnection: isConnection)
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("Corta.SessionEnded")
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        updateColors()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: exit.isCleanExit ? "checkmark.circle" : "exclamationmark.circle",
            accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let newSession = NSButton(
            title: L10n.text(isConnection ? "failure.button.reconnect" : "session.ended.newSession"),
            target: self, action: #selector(newSessionTapped))
        newSession.controlSize = .regular
        newSession.bezelStyle = .rounded
        newSession.toolTip = L10n.text(
            isConnection ? "session.ended.confirm.remoteMessage" : "session.ended.confirm.message")
        newSessionButton = newSession

        let close = NSButton(
            title: L10n.text("menu.closePane"), target: self, action: #selector(closeTapped))
        close.controlSize = .regular
        close.bezelStyle = .inline
        close.contentTintColor = .secondaryLabelColor
        closeButton = close

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, newSession, close])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A described group, with its two buttons reachable inside it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Centers a compact card in `view`, `inset` in from the top or bottom
    /// edge, and announces it. It never takes the keyboard: a key pressed
    /// in a dead pane must not start or close anything.
    func present(in view: NSView, atTop: Bool, inset: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            atTop
                ? topAnchor.constraint(equalTo: view.topAnchor, constant: max(inset, 16))
                : bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -max(inset, 16)),
        ])
        let preferredWidth = widthAnchor.constraint(equalToConstant: 560)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    @objc private func newSessionTapped() { onNewSession?() }
    @objc private func closeTapped() { onClosePane?() }
}
