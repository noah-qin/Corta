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

extension PaneSearch {
    // MARK: - Placement

    /// Gap between a bottom-placed bar and the pane's bottom edge.
    static let bottomMargin: CGFloat = 10

    /// Keeps the bar off what the user is looking at. Top-right is home; while
    /// the cursor or the current match would sit under it there, it moves to
    /// the bottom-right, and comes back once the top is clear. A pane too short
    /// for either to be clear stays where it is.
    ///
    /// Called when the bar opens, when output arrives, when the viewport
    /// scrolls and when the current match changes — a few rect comparisons,
    /// on the main thread, only while a bar is open.
    func placeClearOfContent() {
        guard let container = bar, let top = topConstraint, let bottom = bottomConstraint,
            let host, let terminalView = host.terminalView
        else { return }
        let view = host.view
        let topInset = host.topInset
        // A tab bar appearing moves the chrome; keep the top slot under it.
        if top.constant != topInset + 2 { top.constant = topInset + 2 }
        let size = container.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let bounds = view.bounds
        let x = bounds.maxX - 14 - size.width
        // In `view`'s own coordinates, whichever way up it is.
        func frame(distanceFromTop: CGFloat) -> CGRect {
            let y =
                view.isFlipped ? distanceFromTop : bounds.height - distanceFromTop - size.height
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        let topFrame = frame(distanceFromTop: topInset + 2)
        let bottomFrame = frame(
            distanceFromTop: bounds.height - Self.bottomMargin - size.height)

        var obstacles: [CGRect] = []
        if host.scrollOffset == 0, let cursor = terminalView.cursorRectProvider?() {
            obstacles.append(terminalView.convert(cursor, to: view))
        }
        if let match = currentMatchRect(in: terminalView, host: host) {
            obstacles.append(terminalView.convert(match, to: view))
        }
        func isClear(_ frame: CGRect) -> Bool {
            // A little slack, so a row brushing the pill's shadow counts.
            let padded = frame.insetBy(dx: -4, dy: -4)
            return !obstacles.contains { $0.intersects(padded) }
        }
        let wantsBottom: Bool
        if isClear(topFrame) {
            wantsBottom = false
        } else if isClear(bottomFrame) {
            wantsBottom = true
        } else {
            return
        }
        guard wantsBottom != bottom.isActive else { return }
        top.isActive = !wantsBottom
        bottom.isActive = wantsBottom
        // A fade, not a slide across the output; at once under Reduce Motion.
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SystemAccessibility.duration(0.15)
            container.animator().alphaValue = 1
        }
    }

    /// The current match's first visible row, in terminal-view coordinates;
    /// `nil` when there is none or it is scrolled out of view.
    private func currentMatchRect(in terminalView: TerminalView, host: PaneSearchHost) -> CGRect? {
        guard let index = currentMatchIndex, matches.indices.contains(index),
            let grid = host.snapshot()
        else { return nil }
        let match = matches[index]
        let cell = terminalView.cellSize
        let screenRow = liveRow(match.start.row, in: grid) + host.scrollOffset
        guard screenRow >= 0, screenRow < grid.rows else { return nil }
        // A match that wraps covers the rest of its first row.
        let endColumn =
            match.end.row == match.start.row
            ? match.end.column + 1 : grid.columns
        return CGRect(
            x: TerminalLayout.insets.left + CGFloat(match.start.column) * cell.width,
            y: host.topInset + CGFloat(screenRow) * cell.height,
            width: CGFloat(max(1, endColumn - match.start.column)) * cell.width,
            height: cell.height)
    }
}
