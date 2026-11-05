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
    weak var pane: ViewController?
    private let title = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var displayedProgram: ProgramIcon?
    private var displayedZoom: Bool?
    private var buttons: [NSButton] = []

    private struct Command {
        var symbol: String
        var label: String
        var action: Selector
        var identifier: String
    }

    init(pane: ViewController) {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeControls() -> NSStackView {
        let controls = NSStackView()
        controls.spacing = 2
        controls.setContentHuggingPriority(.required, for: .horizontal)
        let actions: [Command] = [
            .init(symbol: "rectangle.split.2x1", label: TerminalCommand.splitRight.title,
                  action: #selector(splitRight), identifier: "pane.splitRight"),
            .init(symbol: "rectangle.split.1x2", label: TerminalCommand.splitDown.title,
                  action: #selector(splitDown), identifier: "pane.splitDown"),
            .init(symbol: "arrow.up.left.and.arrow.down.right", label: TerminalCommand.zoomPane.title,
                  action: #selector(zoom), identifier: "pane.zoom"),
            .init(symbol: "xmark", label: TerminalCommand.close.title,
                  action: #selector(closePane), identifier: "pane.close"),
        ]
        for command in actions {
            let label = command.label
            let button = NSButton(image: NSImage(systemSymbolName: command.symbol, accessibilityDescription: label)!,
                                  target: self, action: command.action)
            button.setAccessibilityIdentifier(command.identifier)
            button.isBordered = false
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.alphaValue = 0.6
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
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
        if buttons[2].isEnabled != split.hasMultiplePanes { buttons[2].isEnabled = split.hasMultiplePanes }
        let zoomed = split.zoomedPane === pane
        guard displayedZoom != zoomed else { return }
        displayedZoom = zoomed
        let label = L10n.text(zoomed ? "command.unzoomPane" : "command.zoomPane")
        buttons[2].image = NSImage(systemSymbolName: zoomed
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: label)
        buttons[2].toolTip = label
        buttons[2].setAccessibilityLabel(label)
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
