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

/// Pure geometry: how the grid sits in its window. Not on the
/// `@MainActor` `ViewController`, so nonisolated readers (mouse → cell)
/// can use it.
nonisolated enum TerminalLayout {
    /// Below the traffic lights; `.fullSizeContentView` runs the background
    /// to the top.
    static let titlebarHeight: CGFloat = 28
    /// The window's own curvature.
    static let windowCornerRadius: CGFloat = 12
    /// Padding only, or the left column clips. Chrome (titlebar, tab bar) is
    /// measured at runtime from `contentLayoutRect` and added; a fixed value
    /// hid the first row under a tab bar.
    static let insets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
    static var insetWidth: CGFloat { insets.left + insets.right }
    static var insetHeight: CGFloat { insets.top + insets.bottom }
    /// A command-status rule: this far left of the grid, and this wide, in
    /// points — in the left inset, never over a cell. Drawn by the renderer;
    /// its tooltip area is the same rect.
    static let statusRuleOffset: CGFloat = 6
    static let statusRuleWidth: CGFloat = 2

    /// How much chrome overlaps a pane this far below the window top; zero
    /// for lower and interior panes. Shared by `ViewController.topInset` and
    /// `updateFocusRingLayout`, so the grid and focus ring agree.
    static func chromeOverlap(windowChrome: CGFloat, paneDistanceFromTop: CGFloat) -> CGFloat {
        max(0, windowChrome - paneDistanceFromTop)
    }

    /// Which pane edges are window edges (window coordinates), so only those
    /// corners round; an interior corner stays square at the divider.
    /// Booleans, not `CACornerMask`: `TerminalView`'s layer is flipped and
    /// the focus ring's isn't, so each maps its own corners.
    static func exteriorEdges(paneFrameInWindow frame: NSRect, windowSize: NSSize)
        -> (top: Bool, left: Bool, right: Bool)
    {
        (
            top: abs(frame.maxY - windowSize.height) < 1,
            left: abs(frame.minX) < 1,
            right: abs(frame.maxX - windowSize.width) < 1
        )
    }
}
