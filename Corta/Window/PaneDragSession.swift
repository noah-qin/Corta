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

/// One drag of a pane's header. Nothing moves until the drop: until then only a
/// preview is drawn, so a cancel leaves every child's size alone, whichever tab
/// it ended up showing on the way.
@MainActor
final class PaneDragSession {
    enum Over: Equatable {
        case nothing
        case pane(PaneDropPlan.Target<ObjectIdentifier>)
        case tab(String)
    }

    /// A pointer must travel this far before a press on the header is a drag.
    private static let threshold: CGFloat = 4
    /// How long over another tab before that tab shows.
    private static let dwell: TimeInterval = 0.6

    private let pane: ViewController
    private let controller: TerminalWindowController
    private let sourceTab: TerminalTab
    private let window: NSWindow
    private let preview = PaneDropPreviewView()
    private(set) var over: Over = .nothing
    private var dwellTab: String?
    private var dwellStart: TimeInterval = 0

    init?(pane: ViewController, controller: TerminalWindowController) {
        guard let window = controller.window, window.attachedSheet == nil, let sourceTab = pane.splitController?.tab
        else { return nil }
        self.pane = pane
        self.controller = controller
        self.sourceTab = sourceTab
        self.window = window
    }

    /// Runs the gesture, as a selection does: its own event loop, ended by the
    /// button, Esc, or the window or pane going away.
    func track(from event: NSEvent) {
        let start = event.locationInWindow
        var dragging = false
        defer {
            if dragging { NSCursor.pop() }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown]
        while true {
            let next = window.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking, dequeue: true)
            guard window.isKeyWindow, !pane.didTeardown, window.attachedSheet == nil else {
                if dragging { cancel() }
                return
            }
            guard let next else {
                if dragging { update(atWindowPoint: window.mouseLocationOutsideOfEventStream) }
                continue
            }
            switch next.type {
            case .leftMouseDragged:
                let point = next.locationInWindow
                if !dragging, hypot(point.x - start.x, point.y - start.y) >= Self.threshold {
                    dragging = true
                    NSCursor.closedHand.push()
                    begin()
                }
                if dragging { update(atWindowPoint: point) }
            case .leftMouseUp:
                if dragging {
                    update(atWindowPoint: next.locationInWindow)
                    finish()
                }
                return
            case .keyDown where next.keyCode == 53:
                if dragging { cancel() }
                drainUntilMouseUp()
                return
            default:
                break
            }
        }
    }

    /// Esc ended the drag with the button still down: the release is not a drop.
    private func drainUntilMouseUp() {
        _ = window.nextEvent(matching: .leftMouseUp, until: .distantFuture, inMode: .eventTracking, dequeue: true)
    }

    func begin() {
        guard let content = window.contentView else { return }
        preview.frame = .zero
        preview.isHidden = true
        content.addSubview(preview, positioned: .above, relativeTo: nil)
    }

    /// The panes showing now, in `preview`'s space: one if the tab shown has a
    /// zoomed pane, and not the dragged pane's siblings hidden behind a zoom.
    private var visiblePanes: [ViewController] {
        guard let split = controller.selectedTab?.split else { return [] }
        return split.zoomedPane.map { [$0] } ?? split.panes
    }

    func update(atWindowPoint point: NSPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let content = window.contentView else { return }
        let tabs = controller.tabs
        if let index = controller.tabStrip.tabIndex(atWindowPoint: point), tabs.indices.contains(index) {
            let tab = tabs[index]
            over = tab === pane.splitController?.tab ? .nothing : .tab(tab.id)
            if tab !== controller.selectedTab {
                if dwellTab != tab.id {
                    dwellTab = tab.id
                    dwellStart = now
                } else if now - dwellStart >= Self.dwell {
                    controller.selectTab(tab)
                    dwellTab = nil
                }
            }
            controller.tabStrip.highlightDropTarget(over == .nothing ? nil : index)
            preview.isHidden = true
            return
        }
        dwellTab = nil
        controller.tabStrip.highlightDropTarget(nil)
        let local = content.convert(point, from: nil)
        let panes = visiblePanes.map { (id: ObjectIdentifier($0), frame: $0.view.convert($0.view.bounds, to: content)) }
        let planned = PaneDropPlan.target(
            at: local, panes: panes, dragged: ObjectIdentifier(pane), minimum: pane.minimumContentSize,
            gap: PaneSurfaceView.gap)
        // A zoomed pane's real place is smaller than what shows, and measuring it
        // would mean unzooming, which a cancel could not take back. It can only swap.
        var plan = planned
        if controller.selectedTab?.split.zoomedPane != nil, case .edge(let id, _) = planned { plan = .center(id) }
        // Already on that side of it: letting go there would do nothing.
        if case .edge(let id, let direction) = plan, let other = paneShowing(id),
            let split = pane.splitController, other.splitController === split,
            split.tree.isBeside(pane.view, other.view, direction: direction) {
            plan = .none
        }
        over = plan == .none ? .nothing : .pane(plan)
        switch plan {
        case .none:
            preview.isHidden = true
        case .center(let id):
            show(panes.first { $0.id == id }?.frame)
        case .edge(let id, let direction):
            show(landingArea(of: id, among: panes).map { PaneDropPlan.previewFrame(of: $0, direction: direction) })
        }
    }

    /// What the drop divides: the pane, or if the dragged pane is the other half
    /// of its split, the whole split, which that pane grows into as this one leaves.
    private func landingArea(
        of id: ObjectIdentifier, among panes: [(id: ObjectIdentifier, frame: CGRect)]
    ) -> CGRect? {
        if let other = paneShowing(id), let parent = other.view.superview as? NSSplitView,
            pane.view.superview === parent, let content = window.contentView {
            return parent.convert(parent.bounds, to: content)
        }
        return panes.first { $0.id == id }?.frame
    }

    /// Where the preview stands now, nil when it does not show.
    var previewFrame: NSRect? { preview.isHidden ? nil : preview.frame }

    private func show(_ frame: NSRect?) {
        guard let frame else { return }
        preview.frame = frame.insetBy(dx: 2, dy: 2)
        preview.isHidden = false
    }

    private func clearPreview() {
        preview.removeFromSuperview()
        controller.tabStrip.highlightDropTarget(nil)
    }

    /// The tab it started in shows again, and the pane has the keyboard: a tab
    /// shown on the way was only ever a look.
    func cancel() {
        clearPreview()
        if controller.selectedTab !== sourceTab, controller.tabs.contains(where: { $0 === sourceTab }) {
            controller.selectTab(sourceTab)
        }
        pane.splitController?.takeFocus(pane)
    }

    func finish() {
        clearPreview()
        guard let split = pane.splitController else { return }
        // The commands act on the focused pane, and this one may be in a tab
        // no longer showing, focused or not.
        split.noteFocus(pane)
        switch over {
        case .nothing:
            cancel()
        case .tab(let id):
            guard let target = controller.tabs.first(where: { $0.id == id }) else { return cancel() }
            split.moveFocusedPane(to: target)
        case .pane(.none):
            cancel()
        case .pane(.center(let id)):
            guard let other = paneShowing(id) else { return cancel() }
            split.swapFocusedPane(with: other)
        case .pane(.edge(let id, let direction)):
            guard let other = paneShowing(id) else { return cancel() }
            split.moveFocusedPane(beside: other, direction: direction)
        }
        // A move refused (nothing beside, no room) leaves the tab it was left on.
        if pane.splitController?.tab !== controller.selectedTab { cancel() }
    }

    private func paneShowing(_ id: ObjectIdentifier) -> ViewController? {
        visiblePanes.first { ObjectIdentifier($0) == id }
    }
}

/// Where the pane would land. Never takes a click or the pointer.
final class PaneDropPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        updateLayerColors()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
