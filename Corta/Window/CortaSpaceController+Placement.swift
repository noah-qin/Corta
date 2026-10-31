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

extension CortaSpaceController {
    // MARK: - Placing

    /// Where a session goes.
    enum Placement {
        /// The grid's first panel.
        case root
        /// Rebalance a packed grid; -1 identifies the incoming panel.
        case retile(SpaceLayoutRecord)
        /// Beside `target`, on `edge`.
        case split(SpacePaneView, SpaceGrid.Edge)
        /// In `target`'s place; if the session is on screen, the two swap.
        case replace(SpacePaneView)
    }

    /// For a session added without a destination: split the roomiest panel
    /// along its longer side; with no room or at the limit, take the place
    /// of the least recently used panel, never the focused one.
    func automaticPlacement(in project: SpaceProject) -> Placement {
        let leaves = project.tree?.leaves.compactMap { $0 as? SpacePaneView } ?? []
        guard !leaves.isEmpty else { return .root }
        if project.maximized == nil, leaves.count < panelLimit {
            let minimum = minimumPanelSize
            // The roomiest panel that can split at all.
            let sized = leaves.map { (panel: $0, size: size(of: $0, in: project)) }
                .sorted { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
            for candidate in sized {
                if let vertical = SpaceGrid.automaticSplit(of: candidate.size, minimum: minimum) {
                    return .split(candidate.panel, vertical ? .right : .bottom)
                }
            }
            if let layout = balancedAddition(in: project) { return .retile(layout) }
        }
        let focused = project.focused.flatMap { focused in leaves.first { $0.session === focused } }
        let oldest = SpaceGrid.leastRecentlyUsed(leaves, recency: { $0.session.lastUsed }, protected: focused)
        return .replace(oldest ?? leaves[leaves.count - 1])
    }

    /// A panel's size, or what it will be once the window reaches its frame.
    private func size(of panel: SpacePaneView, in project: SpaceProject) -> CGSize {
        if transitionArea != nil, let sizes = project.layout?.panelSizes(in: gridArea),
           let index = project.sessions.firstIndex(where: { $0 === panel.session }), let size = sizes[index] {
            return size
        }
        return panel.frame.size
    }

    /// The size the session will have once placed: what it starts at.
    func plannedSize(of placement: Placement, in project: SpaceProject) -> CGSize {
        switch placement {
        case .root: return gridArea
        case .retile(let layout): return layout.panelSizes(in: gridArea)[-1] ?? gridArea
        case .replace(let target): return size(of: target, in: project)
        case .split(let target, let edge):
            let size = size(of: target, in: project)
            let gap = SpaceGrid.dividerThickness
            return edge.isVertical
                ? CGSize(width: (size.width - gap) / 2, height: size.height)
                : CGSize(width: size.width, height: (size.height - gap) / 2)
        }
    }

    /// Whether `session` can be dropped on `target`'s `edge`: room for two
    /// panels there, and room in the grid for another.
    func canDrop(_ session: SpaceSession, on target: SpacePaneView, edge: SpaceGrid.Edge) -> Bool {
        guard let project = selectedProject, project.maximized == nil, session !== target.session else { return false }
        guard project.shown.contains(session) || project.shown.count < panelLimit else { return false }
        return SpaceGrid.canSplit(target.frame.size, vertical: edge.isVertical, minimum: minimumPanelSize)
    }

    /// Puts the session where `placement` says, changing only the panels
    /// involved.
    func place(_ session: SpaceSession, _ placement: Placement, in project: SpaceProject) {
        guard let new = panel(for: session) else { return }
        var arrived = [session]
        switch placement {
        case .retile(let layout):
            guard let index = project.sessions.firstIndex(of: session) else { return }
            replaceLayout(of: project, with: layout.mapPanels { $0 == -1 ? index : $0 })
            arrived = project.shown
        case .root:
            remove(new, from: project)
            project.tree = SplitTree(root: new, style: .space)
        case .replace(let target) where target === new:
            arrived = []
        case .replace(let target):
            guard let tree = project.tree else { return }
            if project.shown.contains(session) {
                // Two panels on screen trade places.
                let marker = NSView()
                tree.replace(leaf: new, with: marker)
                tree.replace(leaf: target, with: new)
                tree.replace(leaf: marker, with: target)
                arrived.append(target.session)
            } else {
                tree.replace(leaf: target, with: new)
                target.session.pane?.view.removeFromSuperview()
            }
        case .split(let target, let edge):
            remove(new, from: project)
            guard let tree = project.tree else {
                project.tree = SplitTree(root: new, style: .space)
                break
            }
            let node = tree.split(leaf: target, orientation: edge.isVertical ? .columns : .rows, newLeaf: new)
            node.delegate = self
            if edge.isLeading { node.addSubview(new, positioned: .below, relativeTo: target) }
            installRoot(of: project)
            host?.view.layoutSubtreeIfNeeded()
            let axis = node.isVertical ? node.bounds.width : node.bounds.height
            node.setPosition(((axis - SpaceGrid.dividerThickness) / 2).rounded(), ofDividerAt: 0)
            arrived.append(target.session)
        }
        installRoot(of: project)
        host?.view.layoutSubtreeIfNeeded()
        settle(arrived)
    }

    private func balancedAddition(in project: SpaceProject) -> SpaceLayoutRecord? {
        let panels = project.shown.compactMap { project.sessions.firstIndex(of: $0) } + [-1]
        for columns in [true, false] {
            guard let layout = SpaceLayoutRecord.arranged(panels, inColumns: columns) else { continue }
            let minimum = minimumPanelSize
            let fits = layout.panelSizes(in: gridArea).values.allSatisfy {
                $0.width >= minimum.width && $0.height >= minimum.height
            }
            if fits { return layout }
        }
        return nil
    }
}
