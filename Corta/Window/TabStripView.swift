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

/// What the strip needs to draw one tab; built by the window controller.
struct TabStripItem: Equatable {
    var programs: [ProgramIcon]
    var name: String
    var context: String
    var toolTip: String
    var status: ProgramStatus?
    var progress: ProgramProgress?
}

/// What the strip asks of its window (`TerminalWindowController`).
@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, select index: Int)
    func tabStrip(_ strip: TabStripView, close index: Int)
    func tabStrip(_ strip: TabStripView, closeOthersThan index: Int)
    func tabStrip(_ strip: TabStripView, move from: Int, to: Int)
    func tabStrip(_ strip: TabStripView, rename index: Int, to title: String?)
    func tabStripNewTab(_ strip: TabStripView)
}

/// Corta's tab bar (D30): a capsule track in the titlebar row, one tab per
/// slot, titles leading-aligned, the selected tab raised. Plain views and
/// public API only; it sits in a toolbar item.
final class TabStripView: NSView {
    static let height: CGFloat = 28
    weak var delegate: TabStripDelegate?
    private(set) var items: [TabStripItem] = []
    private(set) var selectedIndex = 0
    private var views: [TabItemView] = []
    private var drag: (index: Int, start: NSPoint, moved: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L10n.text("tabs.strip"))
        setAccessibilityIdentifier("tab-strip")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Light or dark follows the terminal canvas, whose colour the
    /// titlebar band shows (D24, amended), not the system's appearance.
    private var isLightCanvas: Bool {
        let color = TerminalColorPalette.defaultBackground
        return color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722 >= 0.5
    }

    func update(items: [TabStripItem], selectedIndex: Int) {
        let name: NSAppearance.Name = isLightCanvas ? .aqua : .darkAqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        let changed = items != self.items || selectedIndex != self.selectedIndex
        self.items = items
        self.selectedIndex = selectedIndex
        while views.count < items.count {
            let view = TabItemView(strip: self)
            views.append(view)
            addSubview(view)
        }
        while views.count > items.count { views.removeLast().removeFromSuperview() }
        for (index, view) in views.enumerated() {
            view.index = index
            view.configure(items[index], selected: index == selectedIndex)
        }
        updateTrack()
        if changed { needsLayout = true; needsDisplay = true }
        setAccessibilityChildren(views)
    }

    /// A lone tab is a pill on its own, no wider than a title needs; the
    /// track appears once there is a second tab to sit beside it.
    static let singleTabWidth: CGFloat = 220

    private func updateTrack() {
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = views.count > 1 ? trackColor.cgColor : nil
    }

    private var trackColor: NSColor {
        let canvas = PaneSurfaceView.canvasColor
        return isLightCanvas
            ? canvas.blended(withFraction: 0.065, of: .black) ?? canvas
            : canvas.blended(withFraction: 0.09, of: .white) ?? canvas
    }

    var selectedFill: NSColor {
        let canvas = PaneSurfaceView.canvasColor
        return isLightCanvas ? .white : canvas.blended(withFraction: 0.2, of: .white) ?? canvas
    }

    override func layout() {
        super.layout()
        guard !views.isEmpty else { return }
        // Flush with the track: the selected pill is the track's own edge.
        let inset: CGFloat = 0
        let width = views.count == 1
            ? min(Self.singleTabWidth, bounds.width - inset * 2)
            : (bounds.width - inset * 2) / CGFloat(views.count)
        for (index, view) in views.enumerated() where !(drag?.moved == true && drag?.index == index) {
            view.frame = NSRect(x: inset + CGFloat(index) * width, y: inset,
                                width: width, height: bounds.height - inset * 2).integral
        }
        needsDisplay = true
    }

    /// Hairlines between two unselected neighbours, as a segmented track.
    override func draw(_ dirtyRect: NSRect) {
        guard views.count > 1 else { return }
        NSColor.separatorColor.setFill()
        for index in 1..<views.count where index != selectedIndex && index - 1 != selectedIndex {
            let x = views[index].frame.minX
            NSRect(x: x - 0.5, y: bounds.height * 0.3, width: 1, height: bounds.height * 0.4).fill()
        }
    }

    // MARK: - Interaction, routed from the tab views

    func itemMouseDown(_ index: Int, event: NSEvent) {
        if event.clickCount == 2 {
            views[index].beginRename()
            return
        }
        delegate?.tabStrip(self, select: index)
        drag = (index, convert(event.locationInWindow, from: nil), false)
    }

    func itemMouseDragged(_ event: NSEvent) {
        guard var current = drag, views.indices.contains(current.index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved, abs(point.x - current.start.x) < 4 { return }
        current.moved = true
        let view = views[current.index]
        let width = view.frame.width
        var frame = view.frame
        frame.origin.x = min(max(0, point.x - width / 2), bounds.width - width)
        view.frame = frame
        addSubview(view, positioned: .above, relativeTo: nil)
        // Swap with the neighbour the dragged tab's centre has crossed into.
        let target = max(0, min(views.count - 1, Int(frame.midX / width)))
        if target != current.index {
            let moving = views.remove(at: current.index)
            views.insert(moving, at: target)
            delegate?.tabStrip(self, move: current.index, to: target)
            current.index = target
        }
        drag = current
        needsLayout = true
    }

    func itemMouseUp() {
        drag = nil
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    func close(_ index: Int) { delegate?.tabStrip(self, close: index) }
    func rename(_ index: Int, to title: String?) { delegate?.tabStrip(self, rename: index, to: title) }

    func menu(forTab index: Int) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = MenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        add(TerminalCommand.newTab.title) { [weak self] in
            guard let self else { return }
            self.delegate?.tabStripNewTab(self)
        }
        add(TerminalCommand.renameTab.title) { [weak self] in
            guard let self else { return }
            self.delegate?.tabStrip(self, select: index)
            self.views[safe: index]?.beginRename()
        }
        menu.addItem(.separator())
        add(L10n.text("tabs.close")) { [weak self] in self?.close(index) }
        if views.count > 1 {
            add(L10n.text("tabs.closeOthers")) { [weak self] in
                guard let self else { return }
                self.delegate?.tabStrip(self, closeOthersThan: index)
            }
        }
        return menu
    }

    func tabView(at index: Int) -> NSView? { views[safe: index] }

    func beginRename(at index: Int) { views[safe: index]?.beginRename() }
}

/// One tab: program icons, name and context leading-aligned, a close button
/// on hover, and an agent badge when a pane reports one.
private final class TabItemView: NSView, NSTextFieldDelegate {
    unowned let strip: TabStripView
    var index = 0
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let badge = AgentTabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private var editor: NSTextField?
    private var hovering = false { didSet { updateChrome() } }
    private var selected = false
    private var item: TabStripItem?

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabStripView.height / 2
        icon.imageScaling = .scaleNone
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("tabs.close"))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel(L10n.text("tabs.close"))
        closeButton.setAccessibilityIdentifier("tab-close")
        for view in [icon, title, badge, closeButton] as [NSView] { addSubview(view) }
        // The tab is the element VoiceOver presses; its parts are not.
        icon.setAccessibilityElement(false)
        title.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("tab-item")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ item: TabStripItem, selected: Bool) {
        guard item != self.item || selected != self.selected else { return }
        self.item = item
        self.selected = selected
        icon.image = TabIcon.image(for: item.programs)
        let text = NSMutableAttributedString(string: item.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        if !item.context.isEmpty {
            text.append(NSAttributedString(string: " " + item.context, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        title.attributedStringValue = text
        toolTip = item.toolTip
        badge.status = item.status
        badge.progress = item.progress
        badge.isHidden = item.status == nil && item.progress == nil
        badge.needsDisplay = true
        setAccessibilityLabel(item.name)
        setAccessibilityValue(selected)
        updateChrome()
        needsLayout = true
    }

    private func updateChrome() {
        layer?.backgroundColor = selected ? strip.selectedFill.cgColor
            : hovering ? NSColor.labelColor.withAlphaComponent(0.04).cgColor : nil
        layer?.shadowOpacity = selected ? 0.12 : 0
        // A hairline keeps a lone white pill visible on a white band.
        layer?.borderWidth = selected ? 0.5 : 0
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.masksToBounds = false
        closeButton.isHidden = !(hovering || selected) || editor != nil
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let size = icon.image?.size ?? .zero
        icon.frame = NSRect(x: 10, y: ((height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
        let closeSide: CGFloat = 16
        closeButton.frame = NSRect(x: bounds.width - closeSide - 8, y: (height - closeSide) / 2,
                                   width: closeSide, height: closeSide)
        badge.frame = NSRect(x: closeButton.frame.minX - 18, y: (height - 16) / 2, width: 16, height: 16)
        let titleX = icon.frame.maxX + 7
        let trailing = badge.isHidden ? closeButton.frame.minX - 4 : badge.frame.minX - 4
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(x: titleX, y: ((height - titleHeight) / 2).rounded(),
                             width: max(0, trailing - titleX), height: titleHeight)
        editor?.frame = title.frame.insetBy(dx: -2, dy: -1)
        // Very narrow tabs keep only the icon.
        title.isHidden = title.frame.width < 24
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if editor != nil { super.mouseDown(with: event); return }
        strip.itemMouseDown(index, event: event)
    }
    override func mouseDragged(with event: NSEvent) { strip.itemMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { strip.itemMouseUp() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip.close(index) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { strip.menu(forTab: index) }

    @objc private func closeTab() { strip.close(index) }

    override func accessibilityPerformPress() -> Bool {
        strip.delegate?.tabStrip(strip, select: index)
        return true
    }

    // MARK: - Rename in place

    func beginRename() {
        guard editor == nil, let item else { return }
        let field = NSTextField(string: item.name)
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.delegate = self
        field.setAccessibilityIdentifier("tab-title-editor")
        editor = field
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        title.isHidden = true
        updateChrome()
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func endRename(save: Bool) {
        guard let field = editor else { return }
        editor = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        title.isHidden = false
        updateChrome()
        needsLayout = true
        // An empty name clears the custom title; Escape keeps the old one.
        if save { strip.rename(index, to: value.isEmpty ? nil : String(value.prefix(200))) }
        window?.makeFirstResponder(window?.terminalSplit?.focusedPane?.terminalView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.stringValue = item?.name ?? ""
            cancelling = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private var cancelling = false

    func controlTextDidEndEditing(_ obj: Notification) {
        let save = !cancelling
        cancelling = false
        endRename(save: save)
    }
}

/// The target of one context-menu item: runs a closure. The item keeps it
/// alive through `representedObject`.
private final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
