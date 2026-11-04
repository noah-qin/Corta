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

// MARK: - Splitting

extension SplitViewController {
    @objc func splitRight(_: Any?) { userSplit(.columns) }
    @objc func splitDown(_: Any?) { userSplit(.rows) }

    /// ⌘D and ⇧⌘D: refused with a beep when either half would be smaller
    /// than a pane can be, rather than leave two crushed panes. A restored
    /// layout is never refused; its dividers are clamped instead.
    private func userSplit(_ orientation: SplitOrientation) {
        splitTransition.finish()
        view.layoutSubtreeIfNeeded()
        guard let focusedPane else { return }
        let bounds = focusedPane.view.bounds
        let minimum = focusedPane.minimumContentSize
        let half = orientation == .columns
            ? (bounds.width - PaneSurfaceView.gap) / 2 : (bounds.height - PaneSurfaceView.gap) / 2
        guard half >= (orientation == .columns ? minimum.width : minimum.height) else {
            NSSound.beep()
            return
        }
        splitFocusedPane(orientation: orientation)
    }

    func splitFocusedPane(
        orientation: SplitOrientation, workingDirectory: String? = nil, preset: Preset? = nil
    ) {
        guard let focusedPane else { return }
        defer {
            noteLayoutChanged()
            (view.window?.windowController as? TerminalWindowController)?.refreshTabTitle()
        }
        // Settle a split still springing open first: measured mid-spring, the
        // pane is a sliver, and halving it crushed both new panes (a quick
        // ⇧⌘D ⇧⌘D left dividers saved at 0.95).
        splitTransition.finish()
        view.layoutSubtreeIfNeeded()
        unzoomPane()
        // The node takes the leaf's old frame and the halves are pre-set, so the
        // first layout is already 50/50 instead of flashing a zero-size pane.
        let oldFrame = focusedPane.view.frame
        let pane = makePane(
            workingDirectory: workingDirectory ?? focusedPane.session?.workingDirectory,
            initialGridSize: halvedGridSize(of: focusedPane, orientation: orientation),
            preset: preset)
        // A window's temporary zoom also applies to newly created panes.
        pane.setFontSize(focusedPane.fontSize)
        pane.isFontSizeZoomed = focusedPane.isFontSizeZoomed
        let node = tree.split(
            leaf: focusedPane.view, orientation: orientation, newLeaf: pane.view)
        node.delegate = self
        (node as? PaneSplitView)?.onDividerInteraction = { [weak self] in
            self?.splitTransition.finish()
        }
        if node === tree.root { installRoot() }
        node.frame = oldFrame
        let (firstFrame, secondFrame) = halvedFrames(of: oldFrame, orientation: orientation)
        focusedPane.view.frame = firstFrame
        pane.view.frame = secondFrame
        updateWindowMinSize()
        view.layoutSubtreeIfNeeded()
        let axis = node.isVertical ? node.bounds.width : node.bounds.height
        node.setPosition((axis - node.dividerThickness) / 2, ofDividerAt: 0)
        // A split is one resize, not a drag: deliver now rather than render the
        // old grid into the halves through the debounce window.
        focusedPane.endLiveResize()
        pane.endLiveResize()
        takeFocus(pane)
        animateSplit(node, newPane: pane)
        for child in panes { child.paneHeader.refresh() }
    }

    /// The two halves of a frame, in the node's flipped coordinates.
    private func halvedFrames(of frame: NSRect, orientation: SplitOrientation)
        -> (NSRect, NSRect)
    {
        let divider = PaneSurfaceView.gap
        if orientation == .columns {
            let width = (frame.width - divider) / 2
            return (
                NSRect(x: 0, y: 0, width: width, height: frame.height),
                NSRect(
                    x: width + divider, y: 0,
                    width: frame.width - width - divider, height: frame.height)
            )
        }
        let height = (frame.height - divider) / 2
        return (
            NSRect(x: 0, y: 0, width: frame.width, height: height),
            NSRect(
                x: 0, y: height + divider,
                width: frame.width, height: frame.height - height - divider)
        )
    }

    /// Half the focused pane's pixel area, minus the divider, in cells.
    private func halvedGridSize(of pane: ViewController, orientation: SplitOrientation)
        -> TerminalSize
    {
        let divider = PaneSurfaceView.gap
        let bounds = pane.view.bounds
        let target =
            orientation == .columns
            ? CGSize(width: (bounds.width - divider) / 2, height: bounds.height)
            : CGSize(width: bounds.width, height: (bounds.height - divider) / 2)
        return pane.gridSize(fitting: target)
    }
}
