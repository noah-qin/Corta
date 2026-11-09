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

import Cocoa

// MARK: - Focus

extension SplitViewController {
    /// Gives `pane` the keyboard. In a tab behind the selected one (D30) it
    /// becomes the tab's focused pane without taking first responder, which
    /// would route the selected tab's typing to a hidden pane.
    func takeFocus(_ pane: TerminalPaneViewController) {
        // Noted first: a pane whose renderer failed has no terminal view to
        // become first responder, and a header button then acted on the
        // pane focused before it.
        noteFocus(pane)
        if isSelectedTab, let terminalView = pane.terminalView {
            view.window?.makeFirstResponder(terminalView)
        }
    }

    func noteFocus(_ pane: TerminalPaneViewController) {
        guard focusedPane !== pane else { return }
        let previous = focusedPane
        focusedPane = pane
        // The cursor draws only in the focused pane: both panes need a redraw.
        previous?.invalidateDisplay()
        pane.invalidateDisplay()
        previous?.focus.applyAppearance()
        pane.focus.applyAppearance()
        for child in panes { child.paneHeader.refresh() }
        applyWindowTitle()
    }

    /// The focused pane's title; a title in an unfocused pane waits for focus.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        // A background tab's title shows in the strip only (D30).
        guard isSelectedTab else {
            tab?.controller?.refreshTabStrip()
            return
        }
        guard let focusedPane else {
            window.title = "Corta"
            window.representedURL = nil
            return
        }
        focusedPane.windowTitle.apply()
    }

    @objc func moveFocusLeft(_: Any?) { moveFocus(.left) }
    @objc func moveFocusRight(_: Any?) { moveFocus(.right) }
    @objc func moveFocusUp(_: Any?) { moveFocus(.up) }
    @objc func moveFocusDown(_: Any?) { moveFocus(.down) }

    /// Leaves zoom before the tree changes: `SplitTree.close(leaf:)` can't
    /// remove a leaf that isn't in it, and `zoomOrigin` names a slot in the
    /// tree as it stood.
    func unzoomIfZoomed() {
        guard isPaneZoomed else { return }
        unzoomPane()
        view.layoutSubtreeIfNeeded()
    }

    /// From a zoomed pane, zoom ends first, as in other terminals: the
    /// neighbour is found in the whole tree, and focusing a pane the zoom
    /// hides would send typing to something off screen.
    private func moveFocus(_ direction: SplitMoveDirection) {
        splitTransition.finish()
        unzoomIfZoomed()
        guard let focusedPane,
            let leaf = tree.leaf(from: focusedPane.view, direction: direction, inContainer: view),
            let target = pane(forLeaf: leaf)
        else { return }
        takeFocus(target)
    }

    /// Focus moves need more than one pane.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectPreviousCortaTab(_:)), #selector(selectNextCortaTab(_:)):
            return (tab?.controller?.tabs.count ?? 0) > 1
        case #selector(renameCurrentTab(_:)):
            return tab != nil
        case #selector(selectCortaTab1(_:)), #selector(selectCortaTab2(_:)), #selector(selectCortaTab3(_:)),
            #selector(selectCortaTab4(_:)), #selector(selectCortaTab5(_:)), #selector(selectCortaTab6(_:)),
            #selector(selectCortaTab7(_:)), #selector(selectCortaTab8(_:)):
            // Only a tab that is there; ⌘9 always has a last one.
            let number = TerminalCommand.tabSelection.first { $0.action == menuItem.action }?.tabNumber ?? 0
            return number <= (tab?.controller?.tabs.count ?? 0)
        case #selector(selectLastCortaTab(_:)):
            return tab?.controller != nil
        case #selector(moveFocusLeft(_:)), #selector(moveFocusRight(_:)),
            #selector(moveFocusUp(_:)), #selector(moveFocusDown(_:)),
            #selector(movePaneLeft(_:)), #selector(movePaneRight(_:)),
            #selector(movePaneUp(_:)), #selector(movePaneDown(_:)),
            #selector(swapPaneLeft(_:)), #selector(swapPaneRight(_:)),
            #selector(swapPaneUp(_:)), #selector(swapPaneDown(_:)):
            return tree != nil && tree.leafCount > 1
        case #selector(movePaneToNewTab(_:)):
            return tree != nil && tree.leafCount > 1 && tab != nil
        case #selector(movePaneToPreviousTab(_:)), #selector(movePaneToNextTab(_:)),
            #selector(movePaneToTabNamedByItem(_:)):
            return (tab?.controller?.tabs.count ?? 0) > 1
        case #selector(splitBestFit(_:)):
            return ConfigurationStore.shared.configuration.bestFitSplit
        case #selector(reopenClosedPane(_:)):
            return canReopenClosedPane
        case #selector(toggleZoomPane(_:)):
            // The title says what the item does now, which a checkmark wouldn't.
            menuItem.title =
                isPaneZoomed
                ? L10n.text("command.unzoomPane") : L10n.text("command.zoomPane")
            return isPaneZoomed || (tree != nil && tree.leafCount > 1)
        default:
            return true
        }
    }

    // MARK: - Font size (broadcast across the window)

    /// ⌘= / ⌘- / ⌘0 apply to every pane of every tab in the window: the
    /// zoom is the window's (`CONFIGURATION.md`, `font-size`), and its panes
    /// share the window's resize increments and minimum size, derived from
    /// one cell geometry. Each pane refits its own grid
    /// (`TerminalPaneViewController.setFontSize`); the window frame stays.
    /// `settle: false` is a pinch still in progress.
    func setFontSizeForAllPanes(_ size: CGFloat, isZoomed: Bool, settle: Bool = true) {
        if let controller = tab?.controller {
            controller.setFontSizeForAllTabs(size, isZoomed: isZoomed, settle: settle)
        } else {
            setFontSizeForOwnPanes(size, isZoomed: isZoomed, settle: settle)
        }
    }

    /// This tab's panes only; the window's broadcast calls it per tab.
    func setFontSizeForOwnPanes(_ size: CGFloat, isZoomed: Bool, settle: Bool) {
        for pane in panes {
            pane.setFontSize(size, settle: settle)
            // On every pane, so each pane's `configurationChanged` agrees.
            pane.isFontSizeZoomed = isZoomed
        }
    }

    /// The end of a pinch: every pane's grid in the window settles at once.
    func settleFontChangeForAllPanes() {
        if let controller = tab?.controller {
            controller.settleFontChangeForAllTabs()
        } else {
            settleFontChangeForOwnPanes()
        }
    }

    func settleFontChangeForOwnPanes() {
        for pane in panes { pane.settleFontChange() }
    }

    // MARK: - Minimum sizes

    /// The tree's minimum plus the chrome; the divider constraints keep drags
    /// from crushing a pane first.
    /// Only the tab in front sets it: the window is shared (D30), and a
    /// background tab's tree recomputes it when it comes to the front
    /// (`didBecomeSelectedTab`).
    func updateWindowMinSize() {
        guard let window = view.window, let pane = panes.first, tab?.isSelected ?? true else { return }
        let treeMinimum = tree.minimumSize(
            of: tree.root, leafSize: leafMinimumSize, dividerThickness: PaneSurfaceView.gap)
        let minimum = NSSize(
            width: treeMinimum.width + 2 * contentMargin,
            height: treeMinimum.height + pane.windowChrome + statusBarHeight + 2 * contentMargin)
        window.contentMinSize = minimum
        // Setting a minimum does not enlarge an already smaller window.
        // Grow it before positioning dividers so both new cards actually fit.
        if !window.styleMask.contains(.fullScreen),
           window.frame.width < minimum.width || window.frame.height < minimum.height {
            var frame = window.frame
            let height = max(frame.height, minimum.height)
            frame.origin.y -= height - frame.height
            frame.size = NSSize(width: max(frame.width, minimum.width), height: height)
            window.setFrame(frame, display: true)
        }
    }

    private func leafMinimumSize(_ leaf: NSView) -> CGSize {
        pane(forLeaf: leaf)?.minimumContentSize ?? .zero
    }

    private func minimumAxis(of subtree: NSView, vertical: Bool) -> CGFloat {
        let size = tree.minimumSize(
            of: subtree, leafSize: leafMinimumSize, dividerThickness: PaneSurfaceView.gap)
        return vertical ? size.width : size.height
    }
}

extension SplitViewController: NSSplitViewDelegate {
    /// Keeps a divider drag from crushing a pane to a 0-column winsize.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMinimumPosition
            + minimumAxis(of: splitView.subviews[dividerIndex], vertical: splitView.isVertical)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMaximumPosition
            - minimumAxis(of: splitView.subviews[dividerIndex + 1], vertical: splitView.isVertical)
    }
}
