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

/// Transparent controls anchored inside the terminal at its top right.
/// Buttons retain their pane identity even when
/// another terminal was the first responder at the time of the click.
final class PaneHeader: NSView {
    static let height: CGFloat = 28
    weak var pane: TerminalPaneViewController?
    private let title = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var displayedProgram: ProgramIcon?
    private var displayedZoom: Bool?
    private var buttons: [NSButton] = []
    /// First in the group: hidden at rest, its slot is the group's leading
    /// edge, so the visible buttons sit together and none moves when it
    /// shows (#529).
    private var zoomButton: NSButton { buttons[0] }
    private var hovering = false

    private struct Command {
        var symbol: String
        var label: String
        var action: Selector
        var identifier: String
    }

    init(pane: TerminalPaneViewController) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: Self.height))
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = makeControls()
        for item in [icon, title, controls] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        let titleEnd = title.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12)
        titleEnd.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleEnd,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeControls() -> NSStackView {
        let controls = NSStackView()
        controls.spacing = 2
        controls.setContentHuggingPriority(.required, for: .horizontal)
        let actions: [Command] = [
            .init(symbol: "arrow.up.left.and.arrow.down.right", label: TerminalCommand.zoomPane.title,
                  action: #selector(zoom), identifier: "pane.zoom"),
            .init(symbol: "rectangle.split.2x1", label: TerminalCommand.splitRight.title,
                  action: #selector(splitRight), identifier: "pane.splitRight"),
            .init(symbol: "rectangle.split.1x2", label: TerminalCommand.splitDown.title,
                  action: #selector(splitDown), identifier: "pane.splitDown"),
            .init(symbol: "xmark", label: TerminalCommand.close.title,
                  action: #selector(closePane), identifier: "pane.close"),
        ]
        for command in actions {
            let label = command.label
            let buttonType: NSButton.Type = command.identifier == "pane.zoom" ? PaneZoomButton.self : NSButton.self
            let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: label)!
            let button = buttonType.init(image: image,
                                  target: self, action: command.action)
            if let zoom = button as? PaneZoomButton {
                zoom.onFocusChange = { [weak self] in self?.refreshZoomVisibility() }
            }
            button.setAccessibilityIdentifier(command.identifier)
            button.isBordered = false
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            controls.addArrangedSubview(button)
            buttons.append(button)
        }
        return controls
    }

    func place() {
        guard let pane else { return }
        frame = NSRect(x: 0, y: pane.view.bounds.height - pane.chromeOverlap - Self.height,
                       width: pane.view.bounds.width, height: Self.height)
        refresh()
    }

    func refresh() {
        guard let pane, let split = pane.splitController else { return }
        let color = TerminalColorPalette.defaultBackground
        let dark = color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722 < 0.5
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        let fullTitle = pane.windowTitle.displayedTitle
        let tabLabel = pane.windowTitle.tabLabel
        if displayedProgram != tabLabel.icon {
            icon.image = tabLabel.icon == .terminal
                ? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) : tabLabel.icon.symbol
            displayedProgram = tabLabel.icon
        }
        // On every output batch while a program streams: touch a view only
        // when its value changed.
        if title.stringValue != tabLabel.text { title.stringValue = tabLabel.text }
        if title.toolTip != fullTitle { title.toolTip = fullTitle }
        let textColor: NSColor = pane.isFocusedPane ? .labelColor : .secondaryLabelColor
        if title.textColor != textColor { title.textColor = textColor }
        refreshSymbolTint()
        if zoomButton.isEnabled != split.hasMultiplePanes { zoomButton.isEnabled = split.hasMultiplePanes }
        refreshZoomVisibility()
        let zoomed = split.zoomedPane === pane
        guard displayedZoom != zoomed else { return }
        displayedZoom = zoomed
        let label = L10n.text(zoomed ? "command.unzoomPane" : "command.zoomPane")
        zoomButton.image = NSImage(systemSymbolName: zoomed
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: label)
        zoomButton.toolTip = label
        zoomButton.setAccessibilityLabel(label)
    }

    /// The icon and the buttons in one tone. Measured at the thin strokes'
    /// darkest or brightest pixel against the header, the buttons drew at
    /// 0.6 alpha on top of the secondary label colour: 3.1–3.7:1 in the
    /// dark themes and 1.8:1 in the light ones. At full secondary they
    /// match the icon (5.3–6.9:1 dark, 3.1:1 light); Increase Contrast takes
    /// the primary label colour, as it promotes secondary labels elsewhere.
    /// An inactive window draws them the same: AppKit does not dim a
    /// borderless button's tint (#531).
    private func refreshSymbolTint() {
        let tint: NSColor = SystemAccessibility.increaseContrast ? .labelColor : .secondaryLabelColor
        if icon.contentTintColor != tint { icon.contentTintColor = tint }
        for button in buttons where button.contentTintColor != tint { button.contentTintColor = tint }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshZoomVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshZoomVisibility()
    }

    private func refreshZoomVisibility() {
        guard !buttons.isEmpty, let split = pane?.splitController else { return }
        let button = zoomButton
        button.isHidden = !split.hasMultiplePanes
        // Preserve the slot while hovering so the adjacent controls stay put;
        // it leads the group, so at rest there is no gap between the others.
        // Keyboard focus and a UI-walking assistive technology keep the same
        // control visible. VoiceOver and Switch Control are the only clients
        // `NSWorkspace` reports; one it cannot report (Voice Control,
        // Accessibility Inspector, a third-party reader) still finds the
        // button in the accessibility tree, since alpha is not
        // `setAccessibilityHidden`; the least surprising choice is to reveal
        // it for the signals that exist rather than for every user (D32).
        let visible = hovering || (button as? PaneZoomButton)?.hasKeyboardFocus == true
            || SystemAccessibility.isVoiceOverOrSwitchControlRunning
        button.alphaValue = visible ? 1 : 0
    }

    private func perform(_ action: (SplitViewController) -> Void) {
        guard let pane, let split = pane.splitController, !pane.didTeardown else { return }
        pane.view.window?.makeFirstResponder(pane.terminalView)
        split.noteFocus(pane)
        action(split)
    }

    @objc private func splitRight() { perform { $0.splitRight(nil) } }
    @objc private func splitDown() { perform { $0.splitDown(nil) } }
    @objc private func zoom() { perform { $0.toggleZoomPane(nil) } }
    @objc private func closePane() { perform { $0.performClose(nil) } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Focuses the pane; held and dragged, rearranges it. A button here tracks
    /// its own click and never reaches this.
    override func mouseDown(with event: NSEvent) {
        perform { _ in }
        guard let pane, !pane.didTeardown, let controller = pane.splitController?.tab?.controller else { return }
        PaneDragSession(pane: pane, controller: controller)?.track(from: event)
    }
}

/// An invisible hover affordance must not intercept a click on the header.
private final class PaneZoomButton: NSButton {
    var onFocusChange: (() -> Void)?
    private(set) var hasKeyboardFocus = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0 ? super.hitTest(point) : nil
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            hasKeyboardFocus = true
            onFocusChange?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hasKeyboardFocus = false
            onFocusChange?()
        }
        return accepted
    }
}
