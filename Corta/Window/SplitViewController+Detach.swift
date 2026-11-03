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

extension SplitViewController {
    /// The same command floats a pane out and embeds a floating group back.
    func detachFocusedPane() {
        if let floating = view.window?.windowController as? FloatingPaneController {
            floating.dock()
            return
        }
        guard let floating = floatFocusedPane() else { return }
        floating.showWindow(nil)
        floating.window?.makeKeyAndOrderFront(nil)
        floating.window?.makeFirstResponder(floating.split.focusedPane?.terminalView)
    }

    @discardableResult
    func floatFocusedPane() -> FloatingPaneController? {
        guard hasMultiplePanes, let pane = focusedPane else { return nil }
        unzoomPane()
        guard let anchor = FloatingPaneController.Anchor(pane: pane),
              var setup = takeFocusedPaneForTransfer() else { return nil }
        setup.isFloating = true
        let floating = FloatingPaneController(source: self, anchor: anchor, setup: setup)
        floatingPanels.append(floating)
        (NSApp.delegate as? AppDelegate)?.track(floating)
        if let owner = view.window, let window = floating.window { owner.addChildWindow(window, ordered: .above) }
        return floating
    }

    /// Removes a leaf without running close/teardown. The destination must
    /// adopt the returned controller before displaying its window.
    func takeFocusedPaneForTransfer() -> Setup? {
        guard hasMultiplePanes, let pane = focusedPane else { return nil }
        unzoomPane()
        let survivor = tree.close(leaf: pane.view)
        pane.removeFromParent()
        focusedPane = panes.first { candidate in
            guard let survivor else { return true }
            return candidate.view === survivor || candidate.view.isDescendant(of: survivor)
        } ?? panes.first
        refreshAfterTransfer()
        noteLayoutChanged()
        return Setup(transferredPane: pane)
    }

    func refreshAfterTransfer() {
        installRoot()
        updateWindowMinSize()
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView(coalesce: false)
            pane.paneHeader.refresh()
            pane.focus.applyAppearance()
        }
        if let focusedPane { takeFocus(focusedPane) }
        applyWindowTitle()
    }

    func prepareFloatingWindowIfNeeded(_ window: NSWindow, pane: ViewController) -> Bool {
        guard isFloating else { return false }
        window.tabbingMode = .disallowed
        window.isRestorable = false
        pane.didSizeWindow = true
        updateWindowMinSize()
        view.layoutSubtreeIfNeeded()
        return true
    }

    func pane(forLeaf leaf: NSView) -> ViewController? {
        panes.first { $0.view === leaf }
    }

    /// Save floating sessions back at their logical docking slots. They are
    /// temporary presentations, never extra permanent windows on next launch.
    func includingFloatingLayouts(_ layout: PaneLayout, beside subtree: NSView) -> PaneLayout {
        floatingPanels.reduce(layout) { result, floating in
            let matches = floating.returnSubtree === subtree
                || (floating.returnSubtree == nil && subtree === layoutRoot)
            guard matches, let extra = floating.layoutForRestoration
            else { return result }
            return .split(vertical: floating.anchor.orientation == .columns,
                          position: Double(floating.anchor.position),
                          first: floating.anchor.wasFirst ? extra : result,
                          second: floating.anchor.wasFirst ? result : extra)
        }
    }

}
