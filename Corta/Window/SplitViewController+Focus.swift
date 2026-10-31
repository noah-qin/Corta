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
    func pane(forLeaf leaf: NSView) -> ViewController? {
        panes.first { $0.view === leaf || $0.view.isDescendant(of: leaf) }
    }

    func noteFocus(_ pane: ViewController) {
        guard focusedPane !== pane else { return }
        let previous = focusedPane
        focusedPane = pane
        // The cursor draws only in the focused pane: both panes need a redraw.
        previous?.invalidateDisplay()
        pane.invalidateDisplay()
        previous?.focus.applyAppearance()
        pane.focus.applyAppearance()
        applyWindowTitle()
        space.noteFocus(pane, previous: previous)
    }

    /// The focused pane's title; a title in an unfocused pane waits for focus.
    func applyWindowTitle() {
        guard let window = view.window else { return }
        if space.isActive {
            space.applyWindowTitle()
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

    private func moveFocus(_ direction: SplitMoveDirection) {
        guard let focusedPane, let tree, let current = leafView(of: focusedPane),
            let leaf = tree.leaf(from: current, direction: direction, inContainer: view),
            let target = pane(forLeaf: leaf)
        else { return }
        view.window?.makeFirstResponder(target.terminalView)
    }

    /// The leaf a pane fills on screen: its own view in a split, its panel
    /// in Space's grid.
    func leafView(of pane: ViewController) -> NSView? {
        space.isActive ? space.leaf(for: pane) : pane.view
    }

    /// Focus moves need more than one pane.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSpaceMode(_:)):
            menuItem.title = L10n.text(space.isActive ? "space.command.showTerminal" : "space.command.showSpace")
            return !(view.window is NSPanel)
        case #selector(jumpToNextWaitingSession(_:)):
            return space.isActive && space.hasWaitingSession()
        case #selector(openSpaceProject(_:)):
            return !(view.window is NSPanel)
        case #selector(arrangeSpaceInColumns(_:)), #selector(arrangeSpaceInRows(_:)):
            return space.isActive && (space.selectedProject?.shown.count ?? 0) > 1
        case #selector(toggleSpaceSidebar(_:)):
            let collapsed = space.splitController.splitViewItems.first?.isCollapsed ?? false
            menuItem.title = L10n.text(collapsed || !space.isActive ? "menu.toggleSidebar" : "menu.hideSidebar")
            return space.isActive
        case #selector(splitRight(_:)) where space.isActive:
            // In Space a new pane is a new session of the project.
            menuItem.title = L10n.text("space.newSession")
            return true
        case #selector(splitRight(_:)):
            menuItem.title = TerminalCommand.splitRight.title
            return true
        case #selector(splitDown(_:)) where space.isActive, #selector(reopenClosedPane(_:)) where space.isActive:
            return false
        case #selector(selectPreviousCortaTab(_:)), #selector(selectNextCortaTab(_:)):
            return (view.window?.tabbedWindows?.count ?? 0) > 1
        case #selector(renameCurrentTab(_:)):
            return view.window != nil
        case #selector(moveFocusLeft(_:)), #selector(moveFocusRight(_:)),
            #selector(moveFocusUp(_:)), #selector(moveFocusDown(_:)):
            return tree != nil && tree.leafCount > 1
        case #selector(reopenClosedPane(_:)):
            return canReopenClosedPane
        case #selector(toggleZoomPane(_:)) where space.isActive:
            let maximized = space.selectedProject?.maximized != nil
            menuItem.title = L10n.text(maximized ? "command.unzoomPane" : "command.zoomPane")
            return maximized || (tree != nil && tree.leafCount > 1)
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

    // MARK: - Font size (broadcast across the tree)

    /// ⌘= / ⌘- / ⌘0 apply to every pane: they share the window's resize
    /// increments and minimum size, derived from one cell geometry.
    /// Each pane refits its own grid (`ViewController.setFontSize`); the
    /// window frame stays. `settle: false` is a pinch still in progress.
    func setFontSizeForAllPanes(_ size: CGFloat, isZoomed: Bool, settle: Bool = true) {
        for pane in panes {
            pane.setFontSize(size, settle: settle)
            // On every pane, so each pane's `configurationChanged` agrees.
            pane.isFontSizeZoomed = isZoomed
        }
    }

    /// The end of a pinch: every pane's grid settles at once.
    func settleFontChangeForAllPanes() {
        for pane in panes { pane.settleFontChange() }
    }

    // MARK: - Minimum sizes

    /// The tree's minimum plus the chrome; the divider constraints keep drags
    /// from crushing a pane first.
    func updateWindowMinSize() {
        guard let window = view.window, let pane = panes.first else { return }
        if space.isActive {
            let minimum = space.minimumContentSize
            window.contentMinSize = NSSize(
                width: minimum.width, height: minimum.height + pane.windowChrome + statusBarHeight)
            return
        }
        let treeMinimum = terminalTree.minimumSize(
            of: terminalTree.root, leafSize: leafMinimumSize, dividerThickness: 1)
        window.contentMinSize = NSSize(
            width: treeMinimum.width,
            height: treeMinimum.height + pane.windowChrome + statusBarHeight)
    }

    private func leafMinimumSize(_ leaf: NSView) -> CGSize {
        pane(forLeaf: leaf)?.minimumContentSize ?? .zero
    }

    private func minimumAxis(of subtree: NSView, vertical: Bool) -> CGFloat {
        let size = terminalTree.minimumSize(of: subtree, leafSize: leafMinimumSize, dividerThickness: 1)
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
