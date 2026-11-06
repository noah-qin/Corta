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

/// `auto-balance-panes`: every pane an equal share along each row, except where
/// the user has placed a divider (`PaneSplitView.isUserPositioned`).
extension SplitTree {
    /// How many equal shares `view` needs along an axis: a row adds its members,
    /// and a split across the axis is as wide as its widest member.
    static func shares(of view: NSView, vertical: Bool) -> Int {
        guard let split = view as? NSSplitView, split.subviews.count == 2 else { return 1 }
        let first = shares(of: split.subviews[0], vertical: vertical)
        let second = shares(of: split.subviews[1], vertical: vertical)
        return split.isVertical == vertical ? first + second : max(first, second)
    }

    /// Where `node`'s divider gives each share the same room, dividers of a
    /// nested row accounted for.
    static func balancedPosition(of node: NSSplitView) -> CGFloat? {
        guard node.subviews.count == 2 else { return nil }
        let axis = node.isVertical ? node.bounds.width : node.bounds.height
        let first = shares(of: node.subviews[0], vertical: node.isVertical)
        let total = first + shares(of: node.subviews[1], vertical: node.isVertical)
        let divider = node.dividerThickness
        let share = (axis - CGFloat(total - 1) * divider) / CGFloat(total)
        return CGFloat(first) * share + CGFloat(first - 1) * divider
    }
}

/// Which way the focused pane splits for Split Pane Along Longer Side.
enum BestFitSplit {
    /// The longer side, in points; the other way if only that leaves both
    /// halves their minimum; nil if neither does.
    static func orientation(size: CGSize, minimum: CGSize, gap: CGFloat) -> SplitOrientation? {
        let columnsFit = (size.width - gap) / 2 >= minimum.width
        let rowsFit = (size.height - gap) / 2 >= minimum.height
        if size.width >= size.height { return columnsFit ? .columns : rowsFit ? .rows : nil }
        return rowsFit ? .rows : columnsFit ? .columns : nil
    }
}

/// `focus-follows-mouse`: the pointer entering a pane focuses it, unless that
/// would interrupt something. Everything it reads is a fact about this moment,
/// so the rule can be tested without a pointer.
struct FocusFollowsMouse {
    var enabled: Bool
    /// The pointer actually moved: a pane appearing under a resting pointer
    /// reports an entry too.
    var pointerMoved: Bool
    /// The app is active, the window key and its tab in front.
    var windowHasKeyboard: Bool
    /// Selecting text, a divider, a dragged file: all hold a button down.
    var buttonPressed: Bool
    /// A menu is open.
    var trackingMenu: Bool
    /// A sheet or modal window is up.
    var modalShowing: Bool
    /// The focused pane's terminal holds the keyboard. If it does not, a search
    /// field or a tab being renamed does, and typing there must not move.
    var terminalHasKeyboard: Bool
    /// An input method is composing in the focused pane.
    var composing: Bool
    /// The pane entered is usable and not already focused.
    var targetCanTakeFocus: Bool

    /// With nothing seen yet there is no evidence of movement: a pane appearing
    /// under a pointer that has rested since launch must not take the keyboard.
    static func pointerMoved(from last: NSPoint?, to location: NSPoint) -> Bool {
        last.map { $0 != location } ?? false
    }

    var shouldFocus: Bool {
        enabled && pointerMoved && windowHasKeyboard && !buttonPressed && !trackingMenu
            && !modalShowing && terminalHasKeyboard && !composing && targetCanTakeFocus
    }
}
