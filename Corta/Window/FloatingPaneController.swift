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

/// A temporary, titlebar-free child window. Its source owns it until docking
/// or closing; the destination controller owns the live PTY throughout.
final class FloatingPaneController: NSWindowController, NSWindowDelegate {
    struct Anchor {
        weak var sibling: NSView?
        var orientation: SplitOrientation
        var wasFirst: Bool
        var position: CGFloat

        init?(pane: ViewController) {
            guard let split = pane.view.superview as? NSSplitView, split.subviews.count == 2,
                  let index = split.subviews.firstIndex(of: pane.view) else { return nil }
            sibling = split.subviews[1 - index]
            orientation = split.isVertical ? .columns : .rows
            wasFirst = index == 0
            let axis = split.isVertical ? split.bounds.width : split.bounds.height
            let extent = split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
            position = axis > 0 ? extent / axis : 0.5
        }
    }

    static let defaultSize = NSSize(width: 420, height: 460)
    private(set) weak var source: SplitViewController?
    let anchor: Anchor
    let split: SplitViewController

    init(source: SplitViewController, anchor: Anchor, setup: SplitViewController.Setup) {
        self.source = source
        self.anchor = anchor
        split = SplitViewController(setup: setup)
        let owner = source.view.window
        let visible = owner?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: Self.defaultSize)
        let size = NSSize(width: min(Self.defaultSize.width, visible.width),
                          height: min(Self.defaultSize.height, visible.height))
        let centre = owner?.frame ?? visible
        let frame = NSRect(x: max(visible.minX, min(centre.midX - size.width / 2, visible.maxX - size.width)),
                           y: max(visible.minY, min(centre.midY - size.height / 2, visible.maxY - size.height)),
                           width: size.width, height: size.height)
        let window = FloatingPaneWindow(contentRect: frame, styleMask: [.borderless, .resizable, .closable],
                                        backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("Corta.FloatingPane")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.animationBehavior = .none
        super.init(window: window)
        window.delegate = self
        window.contentViewController = split
        // AppKit adopts the content controller's placeholder size on install.
        // Apply the standard floating size after attaching the controller.
        window.setFrame(frame, display: false)
        split.prepareWindow(window)
        split.view.layoutSubtreeIfNeeded()
        for pane in split.panes { pane.resizeSessionToFitView(coalesce: false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var returnSubtree: NSView? {
        guard let source, let root = source.layoutRoot, let sibling = anchor.sibling,
              sibling === root || sibling.isDescendant(of: root) else { return nil }
        return sibling
    }

    var layoutForRestoration: PaneLayout? {
        guard let layout = split.windowState(frame: window?.frame ?? .zero)?.layout else { return nil }
        return window?.isKeyWindow == true ? layout : removingFocus(layout)
    }

    private func removingFocus(_ layout: PaneLayout) -> PaneLayout {
        switch layout {
        case .pane(let directory, let preset, _):
            return .pane(directory: directory, presetName: preset, isFocused: false)
        case .split(let vertical, let position, let first, let second):
            return .split(vertical: vertical, position: position,
                          first: removingFocus(first), second: removingFocus(second))
        }
    }

    /// The entire live floating tree can be embedded, even if split while out.
    func dock() {
        guard let source else { return }
        source.unzoomPane()
        split.unzoomPane()
        let focused = source.panes.first { $0 === source.focusedPane }
        guard let sibling = returnSubtree ?? focused?.view ?? source.panes.first?.view,
              let subtree = split.layoutRoot else { return }
        let panes = split.panes
        let focus = split.focusedPane
        subtree.removeFromSuperview()
        for pane in panes {
            pane.removeFromParent()
            source.addChild(pane)
        }
        let originalFrame = sibling.frame
        let node = source.tree.split(leaf: sibling, orientation: anchor.orientation, newLeaf: subtree)
        // A nested node must occupy its sibling's old slot immediately.
        // A zero-width insertion lets its ancestor give all space away.
        node.frame = originalFrame
        node.adjustSubviews()
        node.delegate = source
        (node as? PaneSplitView)?.onDividerInteraction = { [weak source] in source?.splitTransition.finish() }
        if anchor.wasFirst { node.addSubview(subtree, positioned: .below, relativeTo: sibling) }
        source.focusedPane = focus ?? panes.first
        source.refreshAfterTransfer()
        let axis = node.isVertical ? node.bounds.width : node.bounds.height
        node.setPosition(axis * anchor.position, ofDividerAt: 0)
        source.refreshAfterTransfer()
        // Close only after its controllers have been reparented: teardown of
        // the now empty floating controller cannot stop the returned sessions.
        close()
        source.view.window?.makeKeyAndOrderFront(nil)
        source.view.window?.makeFirstResponder(source.focusedPane?.terminalView)
        source.noteLayoutChanged()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = split.panesWithRunningJobs
        guard split.needsCloseConfirmation(for: running) else { return true }
        split.confirmClose(of: running, scope: L10n.text("close.scope.pane"), in: sender) { [weak self] in
            if $0 { self?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        split.teardown()
        if let window { window.parent?.removeChildWindow(window) }
        source?.floatingPanels.removeAll { $0 === self }
        source?.noteLayoutChanged()
    }
}

/// Borderless windows need an explicit keyboard policy; the header supplies
/// the drag region and pane buttons supply close and dock affordances.
final class FloatingPaneWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
