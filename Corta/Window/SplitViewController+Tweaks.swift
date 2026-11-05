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

/// The three optional split behaviours; each is off until its key says so
/// (`auto-balance-panes`, `focus-follows-mouse`, `best-fit-split`).
extension SplitViewController {
    private var configuration: Configuration { ConfigurationStore.shared.configuration }

    // MARK: - Balancing

    /// Gives every pane an equal share after a pane opens or closes, keeping any
    /// divider the user placed. Nothing while restoring or zoomed: a restored
    /// layout is the user's arrangement, and a zoomed tree is not on screen.
    func balancePanesIfConfigured() {
        guard configuration.autoBalancePanes, !isRestoringLayout, zoomedPane == nil else { return }
        notePanesRearranged()
        view.layoutSubtreeIfNeeded()
        balance(tree.root)
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
    }

    private func balance(_ subtree: NSView) {
        guard let split = subtree as? NSSplitView else { return }
        if (split as? PaneSplitView)?.isUserPositioned != true,
            let position = SplitTree.balancedPosition(of: split)
        {
            split.setPosition(position, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        for child in split.subviews { balance(child) }
    }

    /// A restored divider away from its balanced place was put there by the
    /// user in an earlier run. The drag itself is not in the saved layout.
    func noteRestoredDividers() {
        for node in tree.nodes { noteRestoredDivider(of: node) }
    }

    /// One node's share of that rule: also what a reopened pane's divider needs,
    /// since closing the pane took the old node and its mark with it.
    func noteRestoredDivider(of node: NSSplitView) {
        guard let split = node as? PaneSplitView, let position = SplitTree.balancedPosition(of: split)
        else { return }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        let extent = split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
        split.isUserPositioned = axis > 0 && abs(extent - position) / axis > Self.balancedTolerance
    }

    /// A rounding step's worth: a restored layout lands within a cell of its
    /// saved share.
    private static let balancedTolerance: CGFloat = 0.02

    // MARK: - Best fit

    /// Splits along the focused pane's longer side. ⌘D and ⇧⌘D stay as they are.
    @objc func splitBestFit(_: Any?) {
        guard configuration.bestFitSplit else {
            NSSound.beep()
            return
        }
        splitTransition.finish()
        unzoomPane()
        view.layoutSubtreeIfNeeded()
        guard let focusedPane,
            let orientation = BestFitSplit.orientation(
                size: focusedPane.view.bounds.size, minimum: focusedPane.minimumContentSize,
                gap: PaneSurfaceView.gap)
        else {
            NSSound.beep()
            return
        }
        splitFocusedPane(orientation: orientation)
    }

    // MARK: - Focus follows the mouse

    /// The pointer entered `pane`.
    func pointerEntered(_ pane: ViewController) {
        guard configuration.focusFollowsMouse else { return }
        let location = NSEvent.mouseLocation
        defer { Self.lastPointerLocation = location }
        let window = view.window
        let rule = FocusFollowsMouse(
            enabled: true,
            pointerMoved: FocusFollowsMouse.pointerMoved(from: Self.lastPointerLocation, to: location),
            windowHasKeyboard: NSApp.isActive && window?.isKeyWindow == true && isSelectedTab,
            buttonPressed: NSEvent.pressedMouseButtons != 0,
            trackingMenu: RunLoop.current.currentMode == .eventTracking,
            modalShowing: window?.attachedSheet != nil || NSApp.modalWindow != nil,
            terminalHasKeyboard: window?.firstResponder === focusedPane?.terminalView,
            composing: focusedPane?.terminalView?.hasMarkedText() == true,
            targetCanTakeFocus: pane !== focusedPane && pane.isOperable && pane.terminalView != nil)
        if rule.shouldFocus { takeFocus(pane) }
    }

    /// Kept on every move, the setting aside: one turned on later must not read
    /// a point from before it as movement. An entry can then tell a moving
    /// pointer from a pane that appeared under a still one.
    func pointerMoved() {
        Self.lastPointerLocation = NSEvent.mouseLocation
    }

    /// Panes changed places, so the entry that may follow is not the pointer's
    /// doing: from here on, only leaving this point counts as moving. The pointer
    /// can be resting on a divider or a header, where no pane sees it move.
    func notePanesRearranged() { Self.lastPointerLocation = NSEvent.mouseLocation }

    private static var lastPointerLocation: NSPoint?
}
