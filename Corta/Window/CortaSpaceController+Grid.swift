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

/// The grid: each project's free split tree of panels. Every change is made
/// to the tree in place — a split, a close, a replacement — so the panels it
/// does not touch keep their views and drawables, and nothing else redraws.
extension CortaSpaceController: NSSplitViewDelegate {
    /// Where panels go: the content area below the toolbar.
    var gridArea: CGSize { transitionArea ?? content.gridArea }

    /// The grid on screen.
    var gridTree: SplitTree? { selectedProject?.tree }

    /// The smallest panel a split may make: `SpaceGrid.minimumGrid` cells
    /// and a header.
    var minimumPanelSize: CGSize {
        guard let pane = host?.focusedPane ?? host?.panes.first else { return CGSize(width: 480, height: 360) }
        let grid = pane.contentSize(columns: SpaceGrid.minimumGrid.columns, rows: SpaceGrid.minimumGrid.rows)
        return CGSize(width: grid.width, height: grid.height + SpacePaneView.headerHeight)
    }

    func panel(for session: SpaceSession) -> SpacePaneView? {
        guard let pane = session.pane else { return nil }
        let key = ObjectIdentifier(session)
        if let panel = panels[key] { return panel }
        let panel = SpacePaneView(session: session, pane: pane, space: self)
        panels[key] = panel
        return panel
    }

    /// The leaf a pane occupies in the grid, for the window's focus moves and
    /// keyboard resizing.
    func leaf(for pane: ViewController) -> NSView? {
        guard let (_, session) = session(for: pane) else { return nil }
        return panels[ObjectIdentifier(session)]
    }

    // MARK: - Showing

    /// Shows the selected project's grid, building its tree from the saved
    /// layout the first time.
    func rebuildGrid() {
        guard isActive, let host else { return }
        guard let project = selectedProject else {
            content.show(.noProject)
            return
        }
        guard project.isAvailable else { content.show(.unavailable); return }
        // Moving the first responder's view lets AppKit hand focus to
        // another panel; the focus before is the focus after.
        let keep = host.focusedPane
        isRebuildingGrid = true
        defer {
            isRebuildingGrid = false
            if let keep, project.shown.contains(where: { $0.pane === keep }) {
                host.focusedPane = keep
                host.view.window?.makeFirstResponder(keep.terminalView)
            }
        }
        var fractions: SpaceLayoutRecord?
        if project.tree == nil, let layout = project.pendingLayout {
            project.pendingLayout = nil
            project.tree = buildTree(layout, in: project)
            fractions = layout
        }
        installRoot(of: project)
        host.view.layoutSubtreeIfNeeded()
        if let fractions, let root = project.tree?.root { apply(fractions, to: root) }
        settle(project.shown)
    }

    /// The container shows the filled panel, the tree, or why there is none.
    func installRoot(of project: SpaceProject) {
        if let maximized = project.maximized, let panel = panel(for: maximized) {
            content.show(.grid(panel))
        } else if let root = project.tree?.root {
            content.show(.grid(root))
        } else {
            content.show(project.sessions.isEmpty ? .noSessions : .allHidden)
        }
    }

    /// Panels whose session just arrived get their terminal, their size and
    /// a frame; everyone off screen follows the grid's size.
    func settle(_ sessions: [SpaceSession]) {
        guard let host else { return }
        for session in sessions { panel(for: session)?.attachTerminal() }
        host.view.layoutSubtreeIfNeeded()
        for session in sessions {
            session.pane?.resizeSessionToFitView(coalesce: false)
            session.pane?.invalidateDisplay()
            // A frame now, so the panel is never shown empty.
            if session.pane?.view.window != nil { session.pane?.terminalView?.drawNow() }
        }
        resizeOffScreenSessions()
        host.updateWindowMinSize()
        host.updateDirectPresentation()
        // A Metal view moved to a new superview can come back without its
        // last drawable; draw once the hierarchy has settled.
        DispatchQueue.main.async {
            for session in sessions where session.pane?.view.window != nil { session.pane?.terminalView?.drawNow() }
        }
    }

    fileprivate func buildTree(_ layout: SpaceLayoutRecord, in project: SpaceProject) -> SplitTree? {
        let leaves = layout.panels.compactMap { index in
            project.sessions.indices.contains(index) ? panel(for: project.sessions[index]) : nil
        }
        guard let first = leaves.first, leaves.count == layout.panels.count else {
            return leaves.first.map { SplitTree(root: $0, style: .space) }
        }
        let tree = SplitTree(root: first, style: .space)
        var index = 0
        grow(layout, leaves: leaves, index: &index, tree: tree)
        return tree
    }

    /// Replays the record's splits around the leaves, in reading order.
    private func grow(_ node: SpaceLayoutRecord, leaves: [NSView], index: inout Int, tree: SplitTree) {
        guard index < leaves.count else { return }
        switch node {
        case .panel: index += 1
        case .split(let vertical, _, let first, let second):
            let lead = leaves[index]
            let trailIndex = index + first.panels.count
            guard trailIndex < leaves.count else { return }
            tree.split(leaf: lead, orientation: vertical ? .columns : .rows, newLeaf: leaves[trailIndex])
                .delegate = self
            grow(first, leaves: leaves, index: &index, tree: tree)
            grow(second, leaves: leaves, index: &index, tree: tree)
        }
    }

    fileprivate func apply(_ layout: SpaceLayoutRecord, to view: NSView) {
        guard case .split(_, let fraction, let first, let second) = layout,
              let split = view as? NSSplitView, split.subviews.count == 2 else { return }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        if axis > 0 { split.setPosition((axis * CGFloat(fraction)).rounded(), ofDividerAt: 0) }
        split.layoutSubtreeIfNeeded()
        apply(first, to: split.subviews[0])
        apply(second, to: split.subviews[1])
    }

    /// Takes a panel out of the tree; its neighbour fills the space.
    func remove(_ panel: SpacePaneView, from project: SpaceProject) {
        guard let tree = project.tree, tree.leaves.contains(where: { $0 === panel }) else { return }
        if tree.root === panel {
            project.tree = nil
        } else {
            tree.close(leaf: panel)
        }
        panel.session.pane?.view.removeFromSuperview()
        panel.removeFromSuperview()
    }

    /// Fills the grid with one panel, or puts it back where it was.
    func setMaximized(_ session: SpaceSession?, in project: SpaceProject) {
        if let current = project.maximized, let panel = panel(for: current), let origin = project.maximizeOrigin {
            panel.removeFromSuperview()
            origin.split.addSubview(panel, positioned: origin.index == 0 ? .below : .above,
                                    relativeTo: origin.split.subviews.first)
            project.maximized = nil
            project.maximizeOrigin = nil
            installRoot(of: project)
            host?.view.layoutSubtreeIfNeeded()
            if let layout = origin.layout, let root = project.tree?.root { apply(layout, to: root) }
        }
        guard let session, let panel = panel(for: session), let split = panel.superview as? NSSplitView,
              let index = split.subviews.firstIndex(of: panel) else {
            settle(project.shown)
            return
        }
        project.maximizeOrigin = SpaceProject.MaximizeOrigin(split: split, index: index, layout: project.layout)
        project.maximized = session
        panel.removeFromSuperview()
        installRoot(of: project)
        settle([session])
    }

    /// Every session not on screen runs at the size of the grid.
    func resizeOffScreenSessions() {
        let area = gridArea
        guard area.width > 0, area.height > 0 else { return }
        let size = CGSize(width: area.width, height: area.height - SpacePaneView.headerHeight)
        for project in projects {
            for session in project.sessions {
                guard let pane = session.pane, pane.view.window == nil else { continue }
                pane.resizeSessionOffScreen(toFit: size)
            }
        }
    }

    /// The content area changed size; the sessions off screen follow it.
    func gridAreaDidChange() {
        guard isActive, !isRebuildingGrid, !isAnimatingFrame else { return }
        resizeOffScreenSessions()
    }

    // MARK: - Dividers

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRebuildingGrid, !isAnimatingFrame else { return }
        scheduleSave()
    }

    /// A divider never makes a panel smaller than a terminal's own minimum,
    /// as far as the split has room for two.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMinimumPosition + minimumExtent(of: splitView.subviews[dividerIndex], in: splitView)
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMaximumPosition - minimumExtent(of: splitView.subviews[dividerIndex + 1], in: splitView)
    }

    private var panelFloor: CGSize {
        let pane = host?.focusedPane?.minimumContentSize ?? CGSize(width: 200, height: 100)
        return CGSize(width: pane.width, height: pane.height + SpacePaneView.headerHeight)
    }

    private func minimumExtent(of subtree: NSView, in split: NSSplitView) -> CGFloat {
        let floor = panelFloor
        let size = gridTree?.minimumSize(
            of: subtree, leafSize: { _ in floor }, dividerThickness: SpaceGrid.dividerThickness) ?? floor
        let wanted = split.isVertical ? size.width : size.height
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        return min(wanted, max(0, (axis - SpaceGrid.dividerThickness) / 2))
    }

    /// Halves every split again (Equalize Panes).
    func equalizeGrid() {
        guard let root = gridTree?.root else { return }
        equalize(root)
        scheduleSave()
    }

    private func equalize(_ view: NSView) {
        guard let split = view as? NSSplitView, split.subviews.count == 2 else { return }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition(((axis - SpaceGrid.dividerThickness) / 2).rounded(), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        for child in split.subviews { equalize(child) }
    }

    /// The smallest window content: the sidebar, if shown, beside the grid
    /// at its panels' smallest.
    var minimumContentSize: CGSize {
        let floor = panelFloor
        let grid = gridTree.map {
            $0.minimumSize(of: $0.root, leafSize: { _ in floor }, dividerThickness: SpaceGrid.dividerThickness)
        } ?? floor
        let sidebarWidth = splitController.splitViewItems.first.map { $0.isCollapsed ? 0 : $0.minimumThickness } ?? 0
        let gaps = SpaceGrid.dividerThickness * 2
        return CGSize(width: sidebarWidth + max(grid.width, 320) + gaps, height: grid.height + gaps + 40)
    }
}

// MARK: - Before and after a placement

extension CortaSpaceController {
    /// What showing `session` would do, said before it is done: which panel
    /// it would take, or that it adds one.
    func placementHint(for session: SpaceSession) -> String {
        guard let project = session.pane == nil ? nil : selectedProject,
              project.sessions.contains(session) else { return L10n.text("space.hint.add") }
        switch automaticPlacement(in: project) {
        case .root, .retile: return L10n.text("space.hint.add")
        case .split(let target, _):
            return L10n.format("space.hint.beside", SpaceSessionPresentation(session: target.session).title)
        case .replace(let target):
            return L10n.format("space.hint.replace", SpaceSessionPresentation(session: target.session).title)
        }
    }

    /// Records the grid as it is, so the next change can be undone: the
    /// panels and their splits and focus, never a process or its output.
    func registerLayoutUndo(in project: SpaceProject, name: String) {
        guard let undo = host?.view.window?.undoManager else { return }
        let layout = project.layout
        let focused = focusedSession
        undo.registerUndo(withTarget: self) { space in
            MainActor.assumeIsolated { space.restore(layout, focus: focused, in: project, name: name) }
        }
        undo.setActionName(name)
    }

    private func restore(_ layout: SpaceLayoutRecord?, focus: SpaceSession?, in project: SpaceProject, name: String) {
        guard projects.contains(where: { $0 === project }) else { return }
        // Redo is the same restore, the other way.
        registerLayoutUndo(in: project, name: name)
        if project !== selectedProject { selectProject(project) }
        replaceLayout(of: project, with: layout)
        self.focus(focus.flatMap { project.shown.contains($0) ? $0 : nil } ?? project.shown.first)
        scheduleSave()
    }

    /// Puts the project's grid in `layout`'s shape, with the panels it names.
    func replaceLayout(of project: SpaceProject, with layout: SpaceLayoutRecord?) {
        if project.maximized != nil { setMaximized(nil, in: project) }
        for panel in project.tree?.leaves.compactMap({ $0 as? SpacePaneView }) ?? [] {
            panel.session.pane?.view.removeFromSuperview()
            panel.removeFromSuperview()
        }
        project.tree = layout.flatMap { buildTree($0, in: project) }
        installRoot(of: project)
        host?.view.layoutSubtreeIfNeeded()
        if let layout, let root = project.tree?.root { apply(layout, to: root) }
        rebuildGrid()
    }

    /// The panels on screen, re-split in columns (each column its own
    /// heights) or in rows (each row its own widths). A tiled grid shares
    /// one of the two; this chooses which.
    func arrange(inColumns: Bool) {
        guard let project = selectedProject, project.shown.count > 1 else { return }
        let indices = project.shown.compactMap { session in project.sessions.firstIndex { $0 === session } }
        registerLayoutUndo(in: project, name: L10n.text("space.undo.arrange"))
        replaceLayout(of: project, with: SpaceLayoutRecord.arranged(indices, inColumns: inColumns))
        scheduleSave()
    }

    /// The new panel says where it went, once: an outline that fades, or a
    /// still one with Reduce Motion — and a note with Undo.
    func announce(_ session: SpaceSession) {
        panel(for: session)?.announceArrival()
        content.showNote(
            L10n.format("space.note.shown", SpaceSessionPresentation(session: session).title),
            undoTitle: L10n.text("space.note.undo")
        ) { [weak self] in self?.host?.view.window?.undoManager?.undo() }
    }
}
