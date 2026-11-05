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

/// Moving and swapping the focused pane: the running pane itself, in a new
/// place. Nothing here spawns or tears down a session, so the process, its
/// scrollback and its remote and search state go with it.
extension SplitViewController {
    @objc func movePaneLeft(_: Any?) { rearrangeFocusedPane { self.moveLeaf($0, .left) } }
    @objc func movePaneRight(_: Any?) { rearrangeFocusedPane { self.moveLeaf($0, .right) } }
    @objc func movePaneUp(_: Any?) { rearrangeFocusedPane { self.moveLeaf($0, .up) } }
    @objc func movePaneDown(_: Any?) { rearrangeFocusedPane { self.moveLeaf($0, .down) } }
    @objc func swapPaneLeft(_: Any?) { rearrangeFocusedPane { self.swapLeaf($0, .left) } }
    @objc func swapPaneRight(_: Any?) { rearrangeFocusedPane { self.swapLeaf($0, .right) } }
    @objc func swapPaneUp(_: Any?) { rearrangeFocusedPane { self.swapLeaf($0, .up) } }
    @objc func swapPaneDown(_: Any?) { rearrangeFocusedPane { self.swapLeaf($0, .down) } }

    @objc func movePaneToNewTab(_: Any?) {
        guard hasMultiplePanes, let pane = focusedPane, let controller = tab?.controller,
            view.window?.attachedSheet == nil
        else {
            NSSound.beep()
            return
        }
        let keepsSearchFocus = searchHoldsKeyboard(pane)
        detach(pane)
        controller.addTab(setup: Setup(adopting: pane))
        finishMove(of: pane, keepsSearchFocus: keepsSearchFocus)
    }

    @objc func movePaneToPreviousTab(_: Any?) { movePaneToAdjacentTab(offset: -1) }
    @objc func movePaneToNextTab(_: Any?) { movePaneToAdjacentTab(offset: 1) }

    /// A row of Move Pane to Tab, whose item names the tab by id: a title or
    /// an index could name another tab by the time it is chosen.
    @objc func movePaneToTabNamedByItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        movePane(toTabWithID: id)
    }

    func movePane(toTabWithID id: String) {
        guard let target = tab?.controller?.tabs.first(where: { $0.id == id }) else { return }
        moveFocusedPane(to: target)
    }

    private func movePaneToAdjacentTab(offset: Int) {
        guard let tab, let tabs = tab.controller?.tabs, tabs.count > 1,
            let index = tabs.firstIndex(where: { $0 === tab })
        else {
            NSSound.beep()
            return
        }
        moveFocusedPane(to: tabs[(index + offset + tabs.count) % tabs.count])
    }

    // MARK: - By dragging (`PaneDragSession`)

    /// The focused pane stands on `direction`'s side of `anchor`, in this tab or
    /// another of the window. Already there, nothing changes, without a beep.
    func moveFocusedPane(beside anchor: ViewController, direction: SplitMoveDirection) {
        guard let pane = focusedPane, pane !== anchor, let destination = anchor.splitController else { return }
        if destination === self {
            guard !tree.isBeside(pane.view, anchor.view, direction: direction) else { return }
            rearrangeFocusedPane {
                self.tree.place($0, beside: anchor.view, direction: direction)
                return true
            }
            return
        }
        guard let source = tab, let target = destination.tab, let controller = source.controller,
            view.window?.attachedSheet == nil
        else { return }
        let keepsSearchFocus = searchHoldsKeyboard(pane)
        let wasLastPane = !hasMultiplePanes
        detach(pane)
        destination.receive(pane, beside: anchor, direction: direction)
        controller.selectTab(target)
        if wasLastPane { controller.closeTab(source) }
        finishMove(of: pane, keepsSearchFocus: keepsSearchFocus)
    }

    /// The focused pane and `other` change places, each keeping the other's
    /// size, whichever tab of the window `other` is in.
    func swapFocusedPane(with other: ViewController) {
        guard let pane = focusedPane, pane !== other, let destination = other.splitController else { return }
        if destination === self {
            rearrangeFocusedPane { self.tree.swap($0, other.view); return true }
            return
        }
        guard let target = destination.tab, let controller = tab?.controller,
            view.window?.attachedSheet == nil
        else { return }
        let keepsSearchFocus = searchHoldsKeyboard(pane)
        for split in [self, destination] {
            split.splitTransition.finish()
            split.unzoomPane()
            split.view.layoutSubtreeIfNeeded()
        }
        if lastClosedPane?.sibling === pane { lastClosedPane = nil }
        if destination.lastClosedPane?.sibling === other { destination.lastClosedPane = nil }
        let ownFractions = tree.dividerFractions()
        let otherFractions = destination.tree.dividerFractions()
        isRearrangingPanes = true
        destination.isRearrangingPanes = true
        let placeholder = NSView(frame: pane.view.frame)
        tree.replace(leaf: pane.view, with: placeholder)
        destination.tree.replace(leaf: other.view, with: pane.view)
        tree.replace(leaf: placeholder, with: other.view)
        pane.removeFromParent()
        other.removeFromParent()
        addChild(other)
        destination.addChild(pane)
        adoptFont(for: other, from: pane)
        settleTree(fractions: ownFractions)
        destination.settleTree(fractions: otherFractions)
        noteFocus(other)
        destination.noteFocus(pane)
        controller.selectTab(target)
        // Both flags down first: a size delivered during surgery is dropped, and
        // the pane now in this tab is laid out for its new place from here on,
        // hidden or not.
        isRearrangingPanes = false
        destination.isRearrangingPanes = false
        balancePanesIfConfigured()
        deliverSizesAfterMove()
        for remaining in panes { remaining.paneHeader.refresh() }
        finishMove(of: pane, keepsSearchFocus: keepsSearchFocus)
    }

    /// A tab has one font size (`setFontSizeForAllPanes`): each of a swapped
    /// pair takes the size of the tab it arrives in.
    private func adoptFont(for arriving: ViewController, from leaving: ViewController) {
        let (hereZoomed, hereSize) = (leaving.isFontSizeZoomed, leaving.fontSize)
        let (thereZoomed, thereSize) = (arriving.isFontSizeZoomed, arriving.fontSize)
        arriving.isFontSizeZoomed = hereZoomed
        if thereSize != hereSize { arriving.setFontSize(hereSize) }
        leaving.isFontSizeZoomed = thereZoomed
        if thereSize != hereSize { leaving.setFontSize(thereSize) }
    }

    // MARK: - Within the tab

    private func moveLeaf(_ leaf: NSView, _ direction: SplitMoveDirection) -> Bool {
        tree.move(leaf: leaf, direction: direction, inContainer: view)
    }

    private func swapLeaf(_ leaf: NSView, _ direction: SplitMoveDirection) -> Bool {
        guard let neighbour = tree.leaf(from: leaf, direction: direction, inContainer: view) else {
            return false
        }
        tree.swap(leaf, neighbour)
        return true
    }

    /// Runs `surgery` on the focused pane's view, then settles the tree in one
    /// step, so a pane whose size ends up unchanged sends its child nothing and
    /// one whose size changed sends the final size once. Beeps, with nothing
    /// changed, when `surgery` reports the pane can go no further.
    private func rearrangeFocusedPane(_ surgery: (NSView) -> Bool) {
        guard hasMultiplePanes, let pane = focusedPane, view.window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        // Before unzooming, which gives the terminal the keyboard.
        let keepsSearchFocus = searchHoldsKeyboard(pane)
        // Measured unzoomed, like a split: the tree is whole only then.
        splitTransition.finish()
        unzoomPane()
        view.layoutSubtreeIfNeeded()
        let fractions = tree.dividerFractions()
        isRearrangingPanes = true
        defer { isRearrangingPanes = false }
        // `fractions` is keyed by identity: a node the surgery freed could
        // otherwise lend its address, and its share, to one the surgery makes.
        let moved = withExtendedLifetime(tree.nodes) {
            guard surgery(pane.view) else { return false }
            settleTree(fractions: fractions)
            return true
        }
        guard moved else {
            NSSound.beep()
            return
        }
        isRearrangingPanes = false
        finishMove(of: pane, keepsSearchFocus: keepsSearchFocus)
    }

    /// Back on screen with every node wired and each surviving divider where
    /// it was; new nodes halve.
    private func settleTree(fractions: [ObjectIdentifier: Double]) {
        wireNodes()
        installRoot()
        updateWindowMinSize()
        view.layoutSubtreeIfNeeded()
        applyDividerFractions(fractions, subtree: tree.root)
        view.layoutSubtreeIfNeeded()
    }

    /// A node `SplitTree` made answers divider drags as a split's does.
    private func wireNodes() {
        for node in tree.nodes where node.delegate !== self {
            wire(node)
        }
    }

    /// Parent first, kept where both sides fit: `applyDividerPositions`' rule.
    private func applyDividerFractions(_ fractions: [ObjectIdentifier: Double], subtree: NSView) {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else { return }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        if axis > 0 {
            let room = axis - split.dividerThickness
            let low = minimumExtent(of: split.subviews[0], vertical: split.isVertical)
            let high = room - minimumExtent(of: split.subviews[1], vertical: split.isVertical)
            let wanted = fractions[ObjectIdentifier(split)].map { axis * CGFloat($0) } ?? room / 2
            split.setPosition(low <= high ? min(max(wanted, low), high) : room / 2, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        for child in split.subviews { applyDividerFractions(fractions, subtree: child) }
    }

    /// The final sizes, focus, and everything that names the pane's place.
    private func finishMove(of pane: ViewController, keepsSearchFocus: Bool) {
        guard let destination = pane.splitController else { return }
        destination.balancePanesIfConfigured()
        destination.deliverSizesAfterMove()
        destination.takeFocus(pane)
        if keepsSearchFocus { pane.search.show() }
        destination.updateDirectPresentation()
        for other in destination.panes { other.paneHeader.refresh(); other.focus.applyAppearance() }
        pane.updateReaderPriority()
        destination.tab?.controller?.refreshTabStrip()
        AgentDirectory.refresh()
        destination.noteLayoutChanged()
    }

    private func deliverSizesAfterMove() {
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
            pane.invalidateDisplay()
        }
    }

    /// The search bar's field has the keyboard: it keeps it, rather than
    /// sending further typing to the shell.
    private func searchHoldsKeyboard(_ pane: ViewController) -> Bool {
        guard let field = pane.search.field,
            let editor = view.window?.firstResponder as? NSText
        else { return false }
        return editor.delegate === field
    }

    // MARK: - Between tabs

    func moveFocusedPane(to target: TerminalTab) {
        guard let pane = focusedPane, let source = tab, target !== source,
            let controller = tab?.controller, view.window?.attachedSheet == nil
        else {
            NSSound.beep()
            return
        }
        // Before measuring: unzooming a zoomed target gives its pane the keyboard.
        let keepsSearchFocus = searchHoldsKeyboard(pane)
        let responder = view.window?.firstResponder
        guard let orientation = target.split.orientationFitting() else {
            if view.window?.firstResponder !== responder {
                takeFocus(pane)
                if keepsSearchFocus { pane.search.show() }
            }
            NSSound.beep()
            return
        }
        let wasLastPane = !hasMultiplePanes
        detach(pane)
        target.split.receive(pane, orientation: orientation)
        // Selected before the source closes, so its emptied view is never what
        // the closing tab's fade shows.
        controller.selectTab(target)
        if wasLastPane { controller.closeTab(source) }
        finishMove(of: pane, keepsSearchFocus: keepsSearchFocus)
    }

    /// Takes `pane` out of this tree and off this controller, still running.
    /// No reopen record: nothing closed. A record whose position hung on this
    /// pane no longer has one.
    private func detach(_ pane: ViewController) {
        splitTransition.finish()
        unzoomPane()
        if lastClosedPane?.sibling === pane { lastClosedPane = nil }
        view.layoutSubtreeIfNeeded()
        if hasMultiplePanes {
            let fractions = tree.dividerFractions()
            isRearrangingPanes = true
            let survivor = tree.close(leaf: pane.view)
            pane.removeFromParent()
            settleTree(fractions: fractions)
            isRearrangingPanes = false
            balancePanesIfConfigured()
            deliverSizesAfterMove()
            let next = survivor.flatMap { subtree in
                panes.first { $0.view === subtree || $0.view.isDescendant(of: subtree) }
            }
            // The keyboard goes to the moved pane next, so only noted here.
            if let next { noteFocus(next) }
            for other in panes { other.paneHeader.refresh() }
            applyWindowTitle()
        } else {
            pane.view.removeFromSuperview()
            pane.removeFromParent()
            focusedPane = nil
        }
    }

    /// Which way this tab's focused pane can split to take another: side by side
    /// if both halves fit, else stacked; nil if neither does, zoomed again if it
    /// was. Its own minimum, since `receive` gives the newcomer its font.
    private func orientationFitting() -> SplitOrientation? {
        splitTransition.finish()
        let wasZoomed = zoomedPane != nil
        unzoomPane()
        view.frame = view.superview?.bounds ?? view.frame
        view.layoutSubtreeIfNeeded()
        guard let anchor = focusedPane else { return nil }
        let bounds = anchor.view.bounds
        let minimum = anchor.minimumContentSize
        if (bounds.width - PaneSurfaceView.gap) / 2 >= minimum.width { return .columns }
        if (bounds.height - PaneSurfaceView.gap) / 2 >= minimum.height { return .rows }
        if wasZoomed { zoomFocusedPane() }
        return nil
    }

    /// `pane`, from another tab, as this tab's focused pane's new neighbour,
    /// at this tab's font size (`setFontSizeForAllPanes`: a tab has one).
    private func receive(_ pane: ViewController, orientation: SplitOrientation) {
        guard let anchor = focusedPane else { return }
        receive(pane, beside: anchor, orientation: orientation, first: false)
    }

    /// The same, on `direction`'s side of `anchor`.
    private func receive(_ pane: ViewController, beside anchor: ViewController, direction: SplitMoveDirection) {
        splitTransition.finish()
        unzoomPane()
        view.frame = view.superview?.bounds ?? view.frame
        view.layoutSubtreeIfNeeded()
        receive(pane, beside: anchor, orientation: direction.orientation, first: direction.towardFirst)
    }

    private func receive(
        _ pane: ViewController, beside anchor: ViewController, orientation: SplitOrientation, first: Bool
    ) {
        let fractions = tree.dividerFractions()
        let frame = anchor.view.frame
        isRearrangingPanes = true
        defer { isRearrangingPanes = false }
        addChild(pane)
        pane.isFontSizeZoomed = anchor.isFontSizeZoomed
        if pane.fontSize != anchor.fontSize { pane.setFontSize(anchor.fontSize) }
        tree.split(leaf: anchor.view, orientation: orientation, newLeaf: pane.view, newLeafFirst: first).frame = frame
        settleTree(fractions: fractions)
        noteFocus(pane)
    }
}
