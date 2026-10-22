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

/// The card a pane says it stopped with — a session that ended, a
/// connection that failed, a pane that could not start: a symbol, a title,
/// one plain sentence, what the next step costs, the raw detail behind a
/// Details disclosure, and the actions. One design for every way a pane
/// stops, so none of them reads as a different kind of trouble.
///
/// Said in words with a symbol, never by colour alone: the tint is
/// emphasis, and the title carries the meaning.
@MainActor
final class PaneStatusPanel: NSView {
    struct Content {
        var symbol: String
        var tint: NSColor
        var title: String
        var body: String
        /// What the primary action does to what is on screen.
        var note: String?
        /// The raw reason — an exit code, an errno, ssh's own words —
        /// selectable, behind Details.
        var details: String?
    }

    struct Action {
        var title: String
        var isPrimary = false
        var handler: () -> Void
    }

    let content: Content
    private(set) var buttons: [NSButton] = []
    private var handlers: [() -> Void] = []
    private var detailsBox: NSView?
    private(set) var detailsToggle: NSButton?

    /// Widest the text runs, so a sentence stays a sentence in a wide pane.
    static let textWidth: CGFloat = 340

    init(_ content: Content, actions: [Action]) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("Corta.StatusPanel")
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        // Through `NSView.shadow`: AppKit owns a layer-backed view's layer
        // shadow and dropped one set there, leaving a white card with no edge
        // on a light terminal.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        self.shadow = shadow

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .medium)
        icon.contentTintColor = content.tint
        icon.setAccessibilityElement(false)

        let title = NSTextField(wrappingLabelWithString: content.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center
        title.isSelectable = false

        let body = Self.wrapping(content.body, size: 12, color: .secondaryLabelColor)
        var views: [NSView] = [icon, title, body]
        if let note = content.note {
            views.append(Self.wrapping(note, size: 11, color: .tertiaryLabelColor))
        }
        if let details = content.details, !details.isEmpty {
            let (toggle, box) = makeDetails(details)
            views.append(toggle)
            views.append(box)
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.controlSize = .large
            if action.isPrimary { button.bezelColor = .controlAccentColor }
            row.addArrangedSubview(button)
            buttons.append(button)
            handlers.append(action.handler)
        }
        views.append(row)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(14, after: views[views.count - 2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
        ])
        updateColors()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([content.title, content.body, content.note].compactMap { $0 }.joined(separator: ". "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func wrapping(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        return label
    }

    private func makeDetails(_ details: String) -> (NSView, NSView) {
        let toggle = NSButton(title: L10n.text("panel.details"), target: self, action: #selector(toggleDetails(_:)))
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.pushOnPushOff)
        toggle.imagePosition = .imageLeading
        toggle.font = .systemFont(ofSize: 11, weight: .medium)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.setAccessibilityIdentifier("status-panel-details")
        detailsToggle = toggle

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        let text = NSTextField(wrappingLabelWithString: details)
        text.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            box.widthAnchor.constraint(equalToConstant: Self.textWidth),
        ])
        box.isHidden = true
        detailsBox = box
        return (toggle, box)
    }

    @objc private func toggleDetails(_ sender: NSButton) {
        detailsBox?.isHidden = sender.state != .on
    }

    var isShowingDetails: Bool { detailsBox?.isHidden == false }

    @objc private func runAction(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Resolved against this view's own appearance: a `cgColor` read outside
    /// it takes the process's, and a dark window got a white card.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.14)).cgColor
            detailsBox?.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
    }
}

/// Lays a `PaneStatusPanel` over a pane: the pane dimmed behind it, or a
/// plain background where there is nothing to show. Clicks outside the
/// panel go through to the terminal, so what it last showed can still be
/// selected and copied.
@MainActor
final class PaneStatusOverlay: NSView {
    enum Backdrop {
        /// The last output, lightly dimmed and still readable.
        case dim
        /// Nothing behind worth showing: the window background.
        case opaque
    }

    enum Placement {
        case top(CGFloat)
        case bottom(CGFloat)
        case center
    }

    let panel: PaneStatusPanel
    let backdrop: Backdrop

    init(panel: PaneStatusPanel, backdrop: Backdrop) {
        self.panel = panel
        self.backdrop = backdrop
        super.init(frame: .zero)
        wantsLayer = true
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(in view: NSView, placement: Placement) {
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topAnchor.constraint(equalTo: view.topAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        var constraints = [
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ]
        switch placement {
        case .top(let inset):
            constraints.append(panel.topAnchor.constraint(equalTo: topAnchor, constant: inset))
        case .bottom(let inset):
            constraints.append(panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset))
        case .center:
            constraints.append(panel.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        // Wanted, not required: a short pane squeezes the inset first.
        for constraint in constraints.suffix(1) { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate(constraints)
    }

    /// The panel takes clicks; the dim does not.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if backdrop == .dim, hit === self { return nil }
        return hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch backdrop {
            case .dim:
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                // Darker, never lighter: a white veil on a light terminal
                // left the white card nothing to stand out from.
                layer?.backgroundColor =
                    (dark ? NSColor(white: 0, alpha: 0.40) : NSColor(white: 0, alpha: 0.08)).cgColor
            case .opaque:
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
    }
}
