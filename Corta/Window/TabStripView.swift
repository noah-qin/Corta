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
    /// A tab dragged off the strip and let go at `point`, in screen
    /// coordinates: into another window's strip, or a window of its own.
    func tabStrip(_ strip: TabStripView, drop index: Int, atScreenPoint point: NSPoint)
    /// The tab's context menu: Move Tab to New Window.
    func tabStrip(_ strip: TabStripView, moveToNewWindow index: Int)
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
        /// Pulled off the strip: a preview follows the pointer, and letting
        /// go moves the tab to another window or a window of its own.
        var tornOff = false
        /// The last pointer position, in strip coordinates, for the edge
        /// scroll to re-place the tab as the row moves under it.
        var point: NSPoint = .zero
    }
    private var drag: Drag?
    /// The row scrolls while a dragged tab is held at either faded edge.
    private var edgeScroll: Timer?
    /// The torn-off tab's picture under the pointer.
    private var dragPreview: NSWindow?
    /// The capsule behind two or more tabs, and the hairlines between
    /// unselected neighbours: views, so they move with the tabs' animations.
    private let track = NSView()
    private var separators: [NSView] = []
    /// A tab opened or closed since the last layout: the others glide.
    private var reflowsNextLayout = false
    /// Tabs added to a strip already on screen: they spring in at the next
    /// layout, once they have their frame.
    private var arriving: [TabItemView] = []
    /// How far the row is scrolled when its tabs, at their minimum width,
    /// are wider than the strip. Tabs scroll; they never shrink to a card
    /// without a name or a close button.
    private var offset: CGFloat = 0
    /// The selected tab is brought into view at the next layout.
    private var revealsSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.wantsLayer = true
        track.isHidden = true
        addSubview(track)
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
        if selectedIndex != self.selectedIndex || items.count != self.items.count { revealsSelection = true }
        // A tab closed under a drag: the dragged view no longer means the
        // same index. Drop the drag; the tabs settle where they are.
        if items.count != self.items.count { drag = nil }
        self.items = items
        self.selectedIndex = selectedIndex
        // The first tab, and a restored window's tabs, are simply there.
        let animates = !views.isEmpty && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A view stays with its tab, by identity: closing the third tab takes
        // the third view away, rather than the last one with every name after
        // the third shifting along.
        var byID: [String: TabItemView] = [:]
        for view in views { if let id = view.itemID { byID[id] = view } }
        var next: [TabItemView] = []
        for item in items {
            if let view = byID.removeValue(forKey: item.id) {
                next.append(view)
            } else {
                let view = TabItemView(strip: self)
                addSubview(view)
                next.append(view)
                if animates { arriving.append(view) }
            }
        }
        for view in byID.values {
            arriving.removeAll { $0 === view }
            view.cancelRename()
            if animates { leave(view) } else { view.removeFromSuperview() }
        }
        if animates, next.count != views.count { reflowsNextLayout = true }
        views = next
        for (index, view) in views.enumerated() {
            view.index = index
            view.configure(items[index], selected: index == selectedIndex)
        }
        updateTrackColors()
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
        return min(Self.tabWidth, max(Self.minimumTabWidth, bounds.width / CGFloat(views.count)))
    }

    /// Room for the program's card, a few letters and the close button.
    static let minimumTabWidth: CGFloat = 112
    /// The width of the soft edge where tabs scroll out of view.
    private static let fadeWidth: CGFloat = 20

    private var contentWidth: CGFloat { slotWidth * CGFloat(views.count) }
    private var maximumOffset: CGFloat { max(0, contentWidth - bounds.width) }

    /// The offset that shows the selected tab whole, clear of the fades.
    private func offsetRevealingSelection(from offset: CGFloat) -> CGFloat {
        guard views.indices.contains(selectedIndex), maximumOffset > 0 else { return 0 }
        let width = slotWidth
        let minX = CGFloat(selectedIndex) * width
        var offset = offset
        if minX - offset < Self.fadeWidth { offset = minX - Self.fadeWidth }
        if minX + width - offset > bounds.width - Self.fadeWidth {
            offset = minX + width - bounds.width + Self.fadeWidth
        }
        return min(max(0, offset), maximumOffset)
    }

    /// Colours resolved in the strip's own appearance: a layer takes a
    /// `CGColor`, which does not follow light and dark by itself.
    private func updateTrackColors() {
        var trackFill: CGColor?
        var separatorFill: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackFill = trackColor.cgColor
            separatorFill = NSColor.separatorColor.cgColor
        }
        track.layer?.backgroundColor = trackFill
        for separator in separators { separator.layer?.backgroundColor = separatorFill }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTrackColors()
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
        let target = revealsSelection ? offsetRevealingSelection(from: offset) : min(max(0, offset), maximumOffset)
        let scrolled = target != offset && window?.isVisible == true
        offset = target
        revealsSelection = false
        // When a tab arrives or leaves, the others and the track make room,
        // not jump; a scroll to the selected tab glides.
        let reflow = !arriving.isEmpty || scrolled || reflowsNextLayout
        reflowsNextLayout = false
        func place(_ view: NSView, _ frame: NSRect) {
            guard view.frame != frame else { return }
            if reflow, !arriving.contains(where: { $0 === view }) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().frame = frame
                }
            } else {
                view.frame = frame
            }
        }
        let held = drag.flatMap { $0.moved && !$0.tornOff ? $0.index : nil }
        for (index, view) in views.enumerated() where index != held {
            place(view, NSRect(x: CGFloat(index) * width - offset, y: 0, width: width, height: bounds.height).integral)
        }
        layoutTrack(width: width, place: place)
        for view in arriving where view.superview === self { springIn(view) }
        arriving.removeAll()
        updateFadeMask()
    }

    /// The capsule spans the tabs, not the row; a lone tab is a pill on its
    /// own and the track appears with the second. Hairlines part two
    /// unselected neighbours, as a segmented control's do.
    private func layoutTrack(width: CGFloat, place: (NSView, NSRect) -> Void) {
        track.isHidden = views.count < 2
        track.layer?.cornerRadius = bounds.height / 2
        place(track, NSRect(x: -offset, y: 0, width: contentWidth, height: bounds.height))
        let gaps = max(0, views.count - 1)
        while separators.count < gaps {
            let separator = NSView()
            separator.wantsLayer = true
            addSubview(separator, positioned: .above, relativeTo: track)
            separators.append(separator)
        }
        while separators.count > gaps { separators.removeLast().removeFromSuperview() }
        updateTrackColors()
        for (gap, separator) in separators.enumerated() {
            let index = gap + 1
            separator.isHidden = index == selectedIndex || index - 1 == selectedIndex
            place(separator, NSRect(x: CGFloat(index) * width - offset - 0.5, y: (bounds.height * 0.3).rounded(),
                                    width: 1, height: (bounds.height * 0.4).rounded()))
        }
    }

    /// A closing tab shrinks and fades where it stood while the others close
    /// the gap; it leaves the strip once the animation is done.
    private func leave(_ view: TabItemView) {
        guard let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        let (midX, midY) = (view.bounds.midX, view.bounds.midY)
        var end = CATransform3DMakeTranslation(midX, midY, 0)
        end = CATransform3DScale(end, 0.7, 0.7, 1)
        end = CATransform3DTranslate(end, -midX, -midY, 0)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: end)
        shrink.duration = 0.15
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "leave")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                view.removeFromSuperview()
                view.layer?.removeAnimation(forKey: "leave")
                view.alphaValue = 1
            }
        }
    }

    /// Soft edges on the sides where tabs run out of view. The mask reaches
    /// past the strip's top and bottom, so the selected tab's shadow stays.
    private func updateFadeMask() {
        guard let layer else { return }
        let fadesLeading = offset > 0.5
        let fadesTrailing = offset < maximumOffset - 0.5
        guard fadesLeading || fadesTrailing, bounds.width > Self.fadeWidth * 2 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = bounds.insetBy(dx: 0, dy: -8)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let edge = Double(Self.fadeWidth / bounds.width)
        let clear = NSColor.clear.cgColor, opaque = NSColor.black.cgColor
        mask.colors = [fadesLeading ? clear : opaque, opaque, opaque, fadesTrailing ? clear : opaque]
        mask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        layer.mask = mask
    }

    /// A trackpad's sideways swipe, or a mouse wheel, scrolls an overflowing row.
    override func scrollWheel(with event: NSEvent) {
        guard maximumOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var delta = abs(dx) >= abs(dy) ? -dx : -dy
        if !event.hasPreciseScrollingDeltas { delta *= 10 }
        let next = min(max(0, offset + delta), maximumOffset)
        guard next != offset else { return }
        offset = next
        needsLayout = true
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

    // MARK: - Interaction, routed from the tab views

    func itemMouseDown(_ index: Int, event: NSEvent) {
        if event.clickCount == 2 {
            views[index].beginRename()
            return
        }
        delegate?.tabStrip(self, select: index)
        drag = Drag(index: index, start: convert(event.locationInWindow, from: nil))
    }

    /// How far off the strip, up or down, a tab is pulled before it tears
    /// off for another window.
    private static let tearDistance: CGFloat = 24

    func itemMouseDragged(_ event: NSEvent) {
        guard var current = drag, views.indices.contains(current.index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved, abs(point.x - current.start.x) < 4, abs(point.y - current.start.y) < 4 { return }
        current.moved = true
        current.point = point
        let off = point.y < -Self.tearDistance || point.y > bounds.height + Self.tearDistance
        if off != current.tornOff {
            current.tornOff = off
            if off { showDragPreview(of: views[current.index]) } else { hideDragPreview() }
            needsLayout = true
        }
        drag = current
        if current.tornOff {
            stopEdgeScroll()
            moveDragPreview(to: NSEvent.mouseLocation)
            return
        }
        placeDraggedTab()
        updateEdgeScroll(at: point)
    }

    /// The dragged tab under the pointer, swapping with the neighbour its
    /// centre has crossed into. In the row's own coordinates, scrolled by
    /// `offset`.
    private func placeDraggedTab() {
        guard var current = drag, views.indices.contains(current.index) else { return }
        let view = views[current.index]
        let width = slotWidth
        var frame = view.frame
        frame.origin.x = min(max(0, current.point.x + offset - width / 2), width * CGFloat(views.count - 1)) - offset
        view.frame = frame
        addSubview(view, positioned: .above, relativeTo: nil)
        let target = max(0, min(views.count - 1, Int((frame.midX + offset) / width)))
        if target != current.index {
            let moving = views.remove(at: current.index)
            views.insert(moving, at: target)
            delegate?.tabStrip(self, move: current.index, to: target)
            current.index = target
            drag = current
        }
        needsLayout = true
    }

    /// Held at a faded edge of an overflowing row, the dragged tab scrolls
    /// it, so a tab can be carried to a place that was out of view.
    private func updateEdgeScroll(at point: NSPoint) {
        let direction: CGFloat = point.x < Self.fadeWidth ? -1 : point.x > bounds.width - Self.fadeWidth ? 1 : 0
        guard direction != 0, maximumOffset > 0 else {
            stopEdgeScroll()
            return
        }
        guard edgeScroll == nil else { return }
        edgeScroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.drag, !current.tornOff else {
                    self?.stopEdgeScroll()
                    return
                }
                let edge: CGFloat = current.point.x < Self.fadeWidth ? -1
                    : current.point.x > self.bounds.width - Self.fadeWidth ? 1 : 0
                let next = min(max(0, self.offset + edge * 6), self.maximumOffset)
                guard edge != 0, next != self.offset else {
                    self.stopEdgeScroll()
                    return
                }
                self.offset = next
                self.placeDraggedTab()
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    private func stopEdgeScroll() {
        edgeScroll?.invalidate()
        edgeScroll = nil
    }

    func itemMouseUp(_ event: NSEvent) {
        let ended = drag
        drag = nil
        stopEdgeScroll()
        hideDragPreview()
        if let ended, ended.tornOff, items.indices.contains(ended.index) {
            delegate?.tabStrip(self, drop: ended.index, atScreenPoint: NSEvent.mouseLocation)
        }
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    /// Where a tab dropped at `point`, in screen coordinates, would go
    /// among this strip's tabs; nil when the point is not over the strip.
    func insertionIndex(atScreenPoint point: NSPoint) -> Int? {
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let bounds = self.bounds.insetBy(dx: 0, dy: -Self.tearDistance)
        guard bounds.contains(local) else { return nil }
        let width = max(slotWidth, 1)
        return max(0, min(views.count, Int(((local.x + offset) / width).rounded())))
    }

    private func showDragPreview(of view: TabItemView) {
        guard dragPreview == nil, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let preview = NSWindow(contentRect: NSRect(origin: .zero, size: view.bounds.size),
                               styleMask: .borderless, backing: .buffered, defer: false)
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.level = .floating
        preview.ignoresMouseEvents = true
        preview.isReleasedWhenClosed = false
        preview.alphaValue = 0.92
        let picture = NSImageView(image: image)
        picture.wantsLayer = true
        picture.layer?.cornerRadius = view.bounds.height / 2
        picture.layer?.masksToBounds = true
        picture.layer?.backgroundColor = selectedFill.cgColor
        preview.contentView = picture
        dragPreview = preview
        moveDragPreview(to: NSEvent.mouseLocation)
        preview.orderFront(nil)
        view.alphaValue = 0.35
    }

    private func moveDragPreview(to point: NSPoint) {
        guard let preview = dragPreview else { return }
        let size = preview.frame.size
        preview.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    private func hideDragPreview() {
        dragPreview?.orderOut(nil)
        dragPreview = nil
        for view in views where view.alphaValue < 1 { view.alphaValue = 1 }
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
        if views.count > 1 {
            add(L10n.text("menu.moveTabToNewWindow")) { [weak self] in
                guard let self, let index = self.index(ofTab: id) else { return }
                self.delegate?.tabStrip(self, moveToNewWindow: index)
            }
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
