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

/// What a context-menu item does, carried as its represented object.
final class SpaceMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// "Projects", and the one way to add one.
final class SpaceSidebarHeader: NSView {
    let addButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: L10n.text("space.sidebar.projects"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.text("space.openProject"))
        addButton.isBordered = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = L10n.text("space.openProject")
        addButton.setAccessibilityIdentifier("Corta.Space.OpenProject")
        let row = NSStackView(views: [label, NSView(), addButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A project row: folder, name, and how many of its sessions wait on you.
final class SpaceProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("Corta.Space.ProjectCell")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let icon = NSImageView()
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingMiddle
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.textColor = .systemOrange
        imageView = icon
        textField = title
        for child in [icon, title, badge] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ project: SpaceProject, isSelected: Bool) {
        imageView?.image = NSImage(
            systemSymbolName: isSelected ? "folder.fill" : "folder", accessibilityDescription: nil)
        // Its own colour, as the session icons have: left to the list, it
        // went monochrome whenever another app was in front.
        imageView?.contentTintColor = .controlAccentColor
        textField?.stringValue = project.name
        toolTip = (project.path as NSString).abbreviatingWithTildeInPath
        let waiting = project.attentionCount
        badge.stringValue = waiting > 0 ? "\(waiting)" : ""
        badge.toolTip = waiting > 0 ? L10n.text("space.project.waiting") : nil
        setAccessibilityLabel(waiting > 0 ? project.name + ", " + L10n.text("space.project.waiting") : project.name)
    }
}

/// A session row, on one line: kind, name, state. The icon takes the accent
/// while the session is in the grid; the dot keeps the state's colour
/// whether the panel shows or not, since the hidden ones are the ones whose
/// state needs saying.
final class SpaceSessionCell: NSTableCellView {
    struct Content: Equatable {
        var presentation: SpaceSessionPresentation
        var isOnScreen: Bool
        /// For the chosen hidden session: what showing it would do.
        var hint: String?
        /// Off screen: the add button shows while the pointer is over it.
        var canShow = false
    }

    static let identifier = NSUserInterfaceItemIdentifier("Corta.Space.SessionCell")
    private let dot = NSView()
    private let hint = NSTextField(labelWithString: "")
    /// Adds the session to the grid, or puts it in a chosen panel's place.
    let showButton = NSButton()
    private var content: Content?
    private var isHovered = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        showButton.image = NSImage(
            systemSymbolName: "rectangle.badge.plus", accessibilityDescription: L10n.text("space.panel.show"))
        showButton.isBordered = false
        showButton.bezelStyle = .accessoryBarAction
        showButton.contentTintColor = .controlAccentColor
        let trailing = NSStackView(views: [hint, showButton, dot])
        trailing.spacing = 6
        imageView = icon
        textField = title
        for child in [icon, title, trailing] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ content: Content) {
        let presentation = content.presentation
        imageView?.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        imageView?.contentTintColor = content.isOnScreen ? .controlAccentColor : .secondaryLabelColor
        textField?.stringValue = presentation.title
        textField?.textColor = presentation.isRunning ? .labelColor : .tertiaryLabelColor
        let color = presentation.tint ?? (presentation.isRunning ? .quaternaryLabelColor : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color.cgColor
        }
        self.content = content
        hint.stringValue = content.hint ?? ""
        hint.isHidden = content.hint == nil
        updateButton()
        let place = presentation.isRunning
            ? L10n.text(content.isOnScreen ? "space.session.onScreen" : "space.session.offScreen") : nil
        let details = [presentation.state, presentation.detail.isEmpty ? nil : presentation.detail, place]
            .compactMap { $0 }
        toolTip = ([presentation.title] + details).joined(separator: "\n")
        setAccessibilityLabel(([presentation.title] + details).joined(separator: ", "))
    }
}

extension SpaceSessionCell {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateButton()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateButton()
    }

    /// Over a hidden session's row, or on the chosen one: add.
    fileprivate func updateButton() {
        let show = (content?.canShow ?? false) && (isHovered || content?.hint != nil)
        showButton.isHidden = !show
        showButton.toolTip = L10n.text("space.panel.show")
    }
}

/// A row that answers the pointer: the selection's shape, fainter, under
/// any row the pointer is over.
final class SpaceRowView: NSTableRowView {
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// The window's background between Space's islands: the colour behind
/// pages, a step darker than the islands on it.
final class SpaceBackgroundView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A rounded card with a hairline: the sidebar's island. The grid's panels
/// are the same shape in their terminal's colour.
final class SpaceIslandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = SpacePaneView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// The list, with Space's own handling first (`SpaceSidebarController`).
final class SpaceOutlineView: NSOutlineView {
    weak var sidebar: SpaceSidebarController?

    override func mouseDown(with event: NSEvent) {
        if sidebar?.handleMouseDown(event) == true { return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if sidebar?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}
