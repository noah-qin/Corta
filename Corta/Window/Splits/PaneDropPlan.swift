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

import CoreGraphics

/// Where a dragged pane would land. Pure: frames in one coordinate space, y
/// up, and a point. Knows nothing of windows, so every edge and size is tested.
enum PaneDropPlan {
    enum Target<ID: Hashable>: Equatable {
        /// Nowhere: outside every pane, or on the dragged pane itself.
        case none
        /// Standing on that side of the pane.
        case edge(ID, SplitMoveDirection)
        /// Changing places with the pane.
        case center(ID)
    }

    /// How deep an edge reaches: a share of the pane's side, kept usable in a
    /// small pane and from swallowing the middle of a large one.
    static func edgeDepth(ofSide side: CGFloat) -> CGFloat {
        min(side / 2, min(100, max(36, side * 0.28)))
    }

    /// `minimum` is what a pane needs to stay usable. An edge whose half would
    /// be smaller falls through to the middle, which needs no room.
    static func target<ID: Hashable>(
        at point: CGPoint, panes: [(id: ID, frame: CGRect)], dragged: ID?, minimum: CGSize, gap: CGFloat = 0
    ) -> Target<ID> {
        guard let pane = panes.first(where: { $0.frame.contains(point) }), pane.id != dragged else { return .none }
        let frame = pane.frame
        let distances: [(direction: SplitMoveDirection, distance: CGFloat)] = [
            (.left, point.x - frame.minX),
            (.right, frame.maxX - point.x),
            (.down, point.y - frame.minY),
            (.up, frame.maxY - point.y),
        ]
        let hasRoom: (SplitMoveDirection) -> Bool = { direction in
            direction.orientation == .columns
                ? (frame.width - gap) / 2 >= minimum.width : (frame.height - gap) / 2 >= minimum.height
        }
        let reached = distances.filter { edge in
            let side = edge.direction.orientation == .columns ? frame.width : frame.height
            return edge.distance < edgeDepth(ofSide: side) && hasRoom(edge.direction)
        }
        guard let nearest = reached.min(by: { $0.distance < $1.distance }) else { return .center(pane.id) }
        return .edge(pane.id, nearest.direction)
    }

    /// The part of `frame` a drop on `direction`'s edge would take.
    static func previewFrame(of frame: CGRect, direction: SplitMoveDirection) -> CGRect {
        switch direction {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .down: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .up: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}
