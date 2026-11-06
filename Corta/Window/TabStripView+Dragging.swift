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

// MARK: - Dragging: reorder, tear off, edge scroll

extension TabStripView {

    /// Lets go of a drag whose tab closed or whose window went: no mouse-up
    /// will come here, so nothing else would take the preview off the screen.
    func cancelDrag() {
        drag = nil
        stopEdgeScroll()
        hideDragPreview()
    }

    func itemMouseDown(_ index: Int, event: NSEvent) {
        guard views.indices.contains(index) else { return }
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

    func stopEdgeScroll() {
        edgeScroll?.invalidate()
        edgeScroll = nil
    }

    func itemMouseUp() {
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

    func hideDragPreview() {
        dragPreview?.orderOut(nil)
        dragPreview = nil
        for view in views where view.alphaValue < 1 { view.alphaValue = 1 }
    }
}
