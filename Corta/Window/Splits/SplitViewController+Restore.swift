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
import CortaTerminal

/// Split tree ↔ `PaneLayout`. Capture walks the view hierarchy, which is
/// the tree. Restore replays ⌘D's `splitFocusedPane` rather than a second
/// builder that could disagree on dividers, winsize and focus.
extension SplitViewController {
    // MARK: - Capture

    func windowState(frame: NSRect) -> WindowState? {
        // While zoomed the hierarchy holds one pane and the tree is incomplete;
        // save the layout recorded at zoom, or the splits are lost on disk.
        // Tab group, index and selection are the window controller's to fill
        // in (`TerminalWindowController.restorableStates`).
        if let zoomed = layoutBeforeZoom {
            return WindowState(frame: WindowState.Frame(frame), layout: zoomed)
        }
        guard let root = layoutRoot else { return nil }
        return WindowState(frame: WindowState.Frame(frame), layout: layout(of: root))
    }

    private func layout(of subtree: NSView) -> PaneLayout {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else {
            let pane = pane(forView: subtree)
            // A pane that never spawned — a restored connection's panel — has
            // no session to read a directory from; the one it was created
            // with keeps the saved directory across another quit (`#519`).
            return .pane(
                directory: pane?.session?.workingDirectory ?? pane?.inheritedWorkingDirectory,
                presetName: pane?.preset?.name,
                isFocused: pane === focusedPane,
                remote: pane?.restorableRemote)
        }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        let first = split.subviews[0].frame
        let extent = split.isVertical ? first.width : first.height
        return .split(
            vertical: split.isVertical,
            // A zero axis would save NaN, which JSON can't encode.
            position: axis > 0 ? Double(extent / axis) : 0.5,
            first: layout(of: split.subviews[0]),
            second: layout(of: split.subviews[1]))
    }

    private func pane(forView view: NSView) -> TerminalPaneViewController? {
        panes.first { $0.view === view }
    }

    // MARK: - Restore

    /// Rebuilds `layout` around the root pane, already spawned in
    /// `firstDirectory`. Called once the window has settled, so splits have
    /// real frames.
    func restore(layout: PaneLayout) {
        guard let root = focusedPane else { return }
        var focusTarget: TerminalPaneViewController?
        isRestoringLayout = true
        rebuild(layout, at: root, focusTarget: &focusTarget)
        isRestoringLayout = false
        view.layoutSubtreeIfNeeded()
        applyDividerPositions(layout, subtree: view.subviews.first)
        view.layoutSubtreeIfNeeded()
        noteRestoredDividers()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
        // The saved focused pane, else the first.
        takeFocus(focusTarget ?? root)
    }

    /// Resolved against the current config; a vanished preset degrades to
    /// directory-only.
    private func resolvedPreset(named name: String?) -> Preset? {
        guard let name else { return nil }
        return ConfigurationStore.shared.configuration.presets.first { $0.name == name }
    }

    private func rebuild(
        _ node: PaneLayout, at pane: TerminalPaneViewController, focusTarget: inout TerminalPaneViewController?
    ) {
        switch node {
        case .pane(_, _, let isFocused, _):
            if isFocused { focusTarget = pane }
        case .split(let vertical, _, let first, let second):
            focusedPane = pane
            splitFocusedPane(
                orientation: vertical ? .columns : .rows,
                workingDirectory: second.firstDirectory,
                preset: resolvedPreset(named: second.firstPresetName),
                remote: second.firstRemote)
            guard let created = focusedPane, created !== pane else { return }
            rebuild(first, at: pane, focusTarget: &focusTarget)
            rebuild(second, at: created, focusTarget: &focusTarget)
        }
    }

    /// Re-applies dividers when leaving zoom, where AppKit re-halved the split
    /// the pane left.
    func reapplyDividerPositions(_ layout: PaneLayout) {
        view.layoutSubtreeIfNeeded()
        applyDividerPositions(layout, subtree: layoutRoot)
        view.layoutSubtreeIfNeeded()
    }

    /// Dividers go last, after the tree lays out: each split re-halves what
    /// it touches.
    /// Parent first: a child's split is a share of the size its parent gives
    /// it. Each divider is kept where both sides fit their panes' minimum, so
    /// a layout saved crushed — or restored into a smaller window — comes
    /// back usable.
    private func applyDividerPositions(_ node: PaneLayout, subtree: NSView?) {
        guard case .split(_, let position, let first, let second) = node,
            let split = subtree as? NSSplitView, split.subviews.count == 2
        else { return }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        if axis > 0 {
            let room = axis - split.dividerThickness
            let low = minimumExtent(of: split.subviews[0], vertical: split.isVertical)
            let high = room - minimumExtent(of: split.subviews[1], vertical: split.isVertical)
            let saved = axis * CGFloat(position)
            split.setPosition(low <= high ? min(max(saved, low), high) : room / 2, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
        applyDividerPositions(first, subtree: split.subviews[0])
        applyDividerPositions(second, subtree: split.subviews[1])
    }

    /// The least a subtree can be along one axis: its panes' minimum sizes,
    /// summed across splits on that axis.
    func minimumExtent(of subtree: NSView, vertical: Bool) -> CGFloat {
        if let split = subtree as? NSSplitView, split.subviews.count == 2 {
            let first = minimumExtent(of: split.subviews[0], vertical: vertical)
            let second = minimumExtent(of: split.subviews[1], vertical: vertical)
            return split.isVertical == vertical ? first + second + split.dividerThickness : max(first, second)
        }
        guard let pane = pane(forView: subtree) else { return 0 }
        let size = pane.minimumContentSize
        return vertical ? size.width : size.height
    }
}
