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
    func tabStrip(_: TabStripView, select index: Int)
    func tabStrip(_: TabStripView, close index: Int)
    func tabStrip(_: TabStripView, closeOthersThan index: Int)
    func tabStrip(_: TabStripView, move from: Int, to: Int)
    /// By identity: an edit can end while the strip is a refresh behind.
    func tabStrip(_: TabStripView, rename tab: String, to title: String?)
    func tabStripNewTab(_: TabStripView)
    /// A tab dragged off the strip and let go at `point`, in screen
    /// coordinates: into another window's strip, or a window of its own.
    func tabStrip(_: TabStripView, drop index: Int, atScreenPoint point: NSPoint)
    /// The tab's context menu: Move Tab to New Window.
    func tabStrip(_: TabStripView, moveToNewWindow index: Int)
}

/// Corta's tab bar (D30): a capsule track in the titlebar row, one tab per
/// slot, titles leading-aligned, the selected tab raised. Plain views and
/// public API only; it sits in a toolbar item.
final class TabStripView: NSView {
    static let height: CGFloat = 28
    weak var delegate: TabStripDelegate?
    private(set) var items: [TabStripItem] = []
    private(set) var selectedIndex = 0
    /// The tab views in strip order; the drag (`TabStripView+Dragging`)
    /// reorders them as it goes.
    var views: [TabItemView] = []
    /// A tab under the pointer: where the press began, and whether it has
    /// moved far enough to be a drag rather than a click.
    struct Drag {
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
    var drag: Drag?
    /// The row scrolls while a dragged tab is held at either faded edge.
    var edgeScroll: Timer?
    /// The torn-off tab's picture under the pointer.
    var dragPreview: NSWindow?
    /// The capsule behind two or more tabs, and the hairlines between
    /// unselected neighbours: views, so they move with the tabs' animations.
    private let track = NSView()
    /// The raised pill under the selected tab: one view for the strip, so
    /// choosing another tab slides it there rather than lighting one tab
    /// as another goes dark. Above the track and its hairlines, below the
    /// tabs.
    let selection = NSView()
    private var separators: [NSView] = []
    /// A tab opened or closed since the last layout: the others glide.
    private var reflowsNextLayout = false
    /// How long the next layout's movement takes: a close is given a
    /// little longer than an open, so the tab is seen to go.
    private var motionNextLayout = TabStripView.motion
    /// Tabs added to a strip already on screen: they open at the next
    /// layout, once they have their frame.
    private var arriving: [TabItemView] = []
    /// How far the row is scrolled when its tabs, at their minimum width,
    /// are wider than the strip. Tabs scroll; they never shrink to a card
    /// without a name or a close button.
    var offset: CGFloat = 0
    /// The selected tab is brought into view at the next layout.
    private var revealsSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.wantsLayer = true
        track.isHidden = true
        addSubview(track)
        selection.wantsLayer = true
        selection.layer?.masksToBounds = false
        selection.layer?.borderWidth = 0.5
        selection.layer?.shadowOpacity = 0.12
        selection.layer?.shadowRadius = 2
        selection.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        addSubview(selection, positioned: .above, relativeTo: track)
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

    /// The press that started a drag has nowhere to end once the window goes.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancelDrag() }
    }

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
        let selectionMoved = selectedIndex != self.selectedIndex
        if selectedIndex != self.selectedIndex || items.count != self.items.count { revealsSelection = true }
        // A tab closed under a drag: the dragged view no longer means the
        // same index. Drop the drag; the tabs settle where they are.
        if items.count != self.items.count { cancelDrag() }
        self.items = items
        self.selectedIndex = selectedIndex
        // The first tab, and a restored window's tabs, are simply there.
        let animates = !views.isEmpty && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reconcileViews(with: items, animates: animates)
        if animates, selectionMoved { reflowsNextLayout = true }
        for (index, view) in views.enumerated() {
            view.index = index
            view.configure(items[index], selected: index == selectedIndex)
        }
        updateTrackColors()
        if changed { needsLayout = true; needsDisplay = true }
        setAccessibilityChildren(views)
    }

    /// A view stays with its tab, by identity: closing the third tab takes
    /// the third view away, rather than the last one with every name after
    /// the third shifting along.
    private func reconcileViews(with items: [TabStripItem], animates: Bool) {
        var byID: [String: TabItemView] = [:]
        for view in views { if let id = view.itemID { byID[id] = view } }
        var next: [TabItemView] = []
        for item in items {
            if let view = byID.removeValue(forKey: item.id) {
                next.append(view)
                continue
            }
            let view = TabItemView(strip: self)
            addSubview(view)
            next.append(view)
            if animates { arriving.append(view) }
        }
        for view in byID.values {
            arriving.removeAll { $0 === view }
            view.cancelRename()
            if animates {
                motionNextLayout = Self.closeMotion
                leave(view)
            } else {
                view.removeFromSuperview()
            }
        }
        if animates, next.count != views.count { reflowsNextLayout = true }
        views = next
    }

    /// A lone tab is a pill on its own, no wider than a title needs; the
    /// track appears once there is a second tab to sit beside it.
    static let tabWidth: CGFloat = 196

    /// Tabs keep their own width and sit at the leading edge; they share the
    /// row only once there are more than fit. The track spans the tabs, not
    /// the row.
    var slotWidth: CGFloat {
        guard !views.isEmpty else { return 0 }
        return min(Self.tabWidth, max(Self.minimumTabWidth, bounds.width / CGFloat(views.count)))
    }

    /// Room for the program's card, a few letters and the close button.
    static let minimumTabWidth: CGFloat = 112
    /// The width of the soft edge where tabs scroll out of view.
    static let fadeWidth: CGFloat = 20

    private var contentWidth: CGFloat { slotWidth * CGFloat(views.count) }
    var maximumOffset: CGFloat { max(0, contentWidth - bounds.width) }

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
        var pillFill: CGColor?
        var pillEdge: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackFill = trackColor.cgColor
            separatorFill = NSColor.separatorColor.cgColor
            pillFill = selectedFill.cgColor
            // A hairline keeps a lone white pill visible on a white band.
            pillEdge = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        track.layer?.backgroundColor = trackFill
        selection.layer?.backgroundColor = pillFill
        selection.layer?.borderColor = pillEdge
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
        let duration = motionNextLayout
        motionNextLayout = Self.motion
        func place(_ view: NSView, _ frame: NSRect) {
            // A new tab opens from nothing at its leading edge, growing as
            // the track grows to hold it; its contents fade in as it does.
            if arriving.contains(where: { $0 === view }) {
                view.frame = NSRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
                view.alphaValue = 0
            }
            guard view.frame != frame || view.alphaValue < 1 else { return }
            if reflow {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.timingFunction = Self.curve
                    view.animator().frame = frame
                    if arriving.contains(where: { $0 === view }) { view.animator().alphaValue = 1 }
                }
            } else {
                view.frame = frame
            }
        }
        func slot(_ index: Int) -> NSRect {
            NSRect(x: CGFloat(index) * width - offset, y: 0, width: width, height: bounds.height).integral
        }
        let held = drag.flatMap { $0.moved && !$0.tornOff ? $0.index : nil }
        for (index, view) in views.enumerated() where index != held {
            place(view, slot(index))
        }
        layoutTrack(width: width, duration: reflow ? duration : nil, place: place)
        // The pill goes where the selected tab goes; under a tab being
        // dragged it is carried along with it, not animated after it.
        selection.isHidden = !views.indices.contains(selectedIndex)
        selection.layer?.cornerRadius = bounds.height / 2
        if let held, held == selectedIndex {
            selection.frame = views[held].frame
        } else if views.indices.contains(selectedIndex) {
            place(selection, slot(selectedIndex))
        }
        selection.alphaValue = drag?.tornOff == true ? 0.35 : 1
        arriving.removeAll()
        updateFadeMask()
    }

}

// MARK: - Track, animations and menus

extension TabStripView {
    /// The capsule spans the tabs, not the row; a lone tab is a pill on its
    /// own and the track appears with the second. Hairlines part two
    /// unselected neighbours, as a segmented control's do.
    private func layoutTrack(width: CGFloat, duration: TimeInterval?, place: (NSView, NSRect) -> Void) {
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
            // Beside the pill a hairline would show at its edge; it fades
            // as the pill slides up to it, and back as the pill moves on.
            let alpha: CGFloat = index == selectedIndex || index - 1 == selectedIndex ? 0 : 1
            if separator.alphaValue != alpha {
                if let duration {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = duration
                        context.timingFunction = Self.curve
                        separator.animator().alphaValue = alpha
                    }
                } else {
                    separator.alphaValue = alpha
                }
            }
            place(separator, NSRect(x: CGFloat(index) * width - offset - 0.5, y: (bounds.height * 0.3).rounded(),
                                    width: 1, height: (bounds.height * 0.4).rounded()))
        }
    }

    /// One duration and one curve for every movement in the strip: a tab
    /// opening or closing, its neighbours making room, the track growing or
    /// shrinking and the selection moving all start and land together.
    static let motion: TimeInterval = 0.3
    static let closeMotion: TimeInterval = 0.38
    /// Quick to leave, slow to land: the pill is under way the moment the
    /// tab is chosen and settles softly, with no overshoot.
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// A closing tab is the opening run backwards: its trailing edge
    /// draws back to its leading one, erasing it right to left over a name
    /// that holds still, and the tab after it follows that edge into the
    /// space. It leaves the strip once that is done.
    private func leave(_ view: TabItemView) {
        view.isLeaving = true
        // Under the tabs that close the gap, above the selection pill.
        addSubview(view, positioned: .above, relativeTo: selection)
        var end = view.frame
        end.size.width = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.closeMotion
            context.timingFunction = Self.curve
            view.animator().frame = end
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                view.removeFromSuperview()
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

    // MARK: - Interaction, routed from the tab views
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

    /// The tab under a point in the window's coordinates, or nil.
    func tabIndex(atWindowPoint point: NSPoint) -> Int? {
        views.firstIndex { !$0.isHidden && $0.bounds.contains($0.convert(point, from: nil)) }
    }

    /// Marks the tab a dragged pane would land in. One at most.
    func highlightDropTarget(_ index: Int?) {
        for (position, view) in views.enumerated() {
            view.wantsLayer = true
            view.layer?.borderWidth = position == index ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

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
