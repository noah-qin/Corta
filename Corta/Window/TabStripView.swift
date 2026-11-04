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
    /// The tab's identity (`TerminalTab.id`): what a rename or a menu
    /// command holds on to while the tabs around it close or move.
    var id: String
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
    /// By identity: an edit can end while the strip is a refresh behind.
    func tabStrip(_ strip: TabStripView, rename tab: String, to title: String?)
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
    /// A tab under the pointer: where the press began, and whether it has
    /// moved far enough to be a drag rather than a click.
    private struct Drag {
        var index: Int
        var start: NSPoint
        var moved = false
    }
    private var drag: Drag?
    /// Tabs added to a strip already on screen: they spring in at the next
    /// layout, once they have their frame.
    private var arriving: [TabItemView] = []

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
    /// The strip's empty part is titlebar; its tabs say otherwise for
    /// themselves (`TabItemView.mouseDownCanMoveWindow`).
    override var mouseDownCanMoveWindow: Bool { true }
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
        // A tab closed under a drag: the dragged view no longer means the
        // same index. Drop the drag; the tabs settle where they are.
        if items.count != self.items.count { drag = nil }
        self.items = items
        self.selectedIndex = selectedIndex
        // The first tab, and a restored window's tabs, are simply there.
        let springs = !views.isEmpty && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        while views.count < items.count {
            let view = TabItemView(strip: self)
            views.append(view)
            addSubview(view)
            if springs { arriving.append(view) }
        }
        while views.count > items.count {
            let view = views.removeLast()
            arriving.removeAll { $0 === view }
            view.cancelRename()
            view.removeFromSuperview()
        }
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
    static let tabWidth: CGFloat = 196

    /// Tabs keep their own width and sit at the leading edge; they share the
    /// row only once there are more than fit. The track spans the tabs, not
    /// the row.
    private var slotWidth: CGFloat {
        guard !views.isEmpty else { return 0 }
        return min(Self.tabWidth, bounds.width / CGFloat(views.count))
    }

    private func updateTrack() {
        layer?.backgroundColor = nil
        needsDisplay = true
    }

    private var trackColor: NSColor {
        // One step from the band it sits on.
        let ground = PaneSurfaceView.gutterColor
        return isLightCanvas
            ? ground.blended(withFraction: 0.045, of: .black) ?? ground
            : ground.blended(withFraction: 0.08, of: .white) ?? ground
    }

    var selectedFill: NSColor {
        let canvas = PaneSurfaceView.canvasColor
        return isLightCanvas ? .white : canvas.blended(withFraction: 0.2, of: .white) ?? canvas
    }

    override func layout() {
        super.layout()
        guard !views.isEmpty else { return }
        // Flush with the track: the selected pill is the track's own edge.
        let width = slotWidth
        // When a tab arrives, the others narrow to make room, not jump.
        let reflow = !arriving.isEmpty
        for (index, view) in views.enumerated() where !(drag?.moved == true && drag?.index == index) {
            let frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).integral
            if reflow, !arriving.contains(where: { $0 === view }), view.frame != frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().frame = frame
                }
            } else {
                view.frame = frame
            }
        }
        for view in arriving where view.superview === self { springIn(view) }
        arriving.removeAll()
        needsDisplay = true
    }

    /// A new tab grows from its centre with a little overshoot. The
    /// animation is presentation only: the layer's own transform stays
    /// identity, so nothing AppKit sets later fights it.
    private func springIn(_ view: TabItemView) {
        guard let layer = view.layer else { return }
        let (midX, midY) = (view.bounds.midX, view.bounds.midY)
        var start = CATransform3DMakeTranslation(midX, midY, 0)
        start = CATransform3DScale(start, 0.6, 0.6, 1)
        start = CATransform3DTranslate(start, -midX, -midY, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 17
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "arrive")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        layer.add(fade, forKey: "arrive.fade")
    }

    /// Hairlines between two unselected neighbours, as a segmented track.
    override func draw(_ dirtyRect: NSRect) {
        guard views.count > 1 else { return }
        // A lone tab is a pill on its own; the track appears with the second.
        let track = NSRect(x: 0, y: 0, width: slotWidth * CGFloat(views.count), height: bounds.height)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
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
        drag = Drag(index: index, start: convert(event.locationInWindow, from: nil))
    }

    func itemMouseDragged(_ event: NSEvent) {
        guard var current = drag, views.indices.contains(current.index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved, abs(point.x - current.start.x) < 4 { return }
        current.moved = true
        let view = views[current.index]
        let width = view.frame.width
        var frame = view.frame
        frame.origin.x = min(max(0, point.x - width / 2), width * CGFloat(views.count - 1))
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

    /// The tab's index now, or nil once it has closed.
    func index(ofTab id: String) -> Int? { items.firstIndex { $0.id == id } }

    /// Renames the tab `id` names, wherever it has moved; nothing if it closed.
    func rename(tab id: String, to title: String?) {
        delegate?.tabStrip(self, rename: id, to: title)
    }

    /// The menu acts on the tab it opened over, found by identity when an
    /// item runs: tabs may close or move while the menu is up.
    func menu(forTab opened: Int) -> NSMenu {
        let menu = NSMenu()
        guard let id = items[safe: opened]?.id else { return menu }
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
            guard let self, let index = self.index(ofTab: id) else { return }
            self.delegate?.tabStrip(self, select: index)
            self.views[safe: index]?.beginRename()
        }
        menu.addItem(.separator())
        add(L10n.text("tabs.close")) { [weak self] in
            guard let self, let index = self.index(ofTab: id) else { return }
            self.close(index)
        }
        if views.count > 1 {
            add(L10n.text("tabs.closeOthers")) { [weak self] in
                guard let self, let index = self.index(ofTab: id) else { return }
                self.delegate?.tabStrip(self, closeOthersThan: index)
            }
        }
        return menu
    }

    func tabView(at index: Int) -> NSView? { views[safe: index] }

    func beginRename(at index: Int) { views[safe: index]?.beginRename() }
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
