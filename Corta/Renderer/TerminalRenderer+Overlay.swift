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
import CortaTerminal
import Foundation
import simd

/// What draws over the cells: cursor, selection, search matches, the hovered link and command marks.
nonisolated extension TerminalRenderer {
    func rebuildOverlay(
        grid: Grid, cursorStyle: CursorStyle, cursorVisible: Bool, selection: TerminalSelection?, offset: Int,
        searchMatches: [TerminalSelection] = [], currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil
    ) {
        let cellWidth = Float(metricsValue.cellWidth)
        let cellHeight = Float(metricsValue.cellHeight)
        overlayScratch.removeAll(keepingCapacity: true)
        if let selection {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    selection, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: frameOverlay.selection))
        }
        // After the selection, before the cursor, which stays on top.
        for (index, match) in searchMatches.enumerated() {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    match, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: index == currentSearchMatchIndex
                        ? frameOverlay.currentSearchMatch : frameOverlay.searchMatch))
        }
        // A rule, not a fill: it must read as a link and not fight the
        // selection.
        if let hoveredLink {
            for quad in selectionQuads(
                hoveredLink, grid: grid, offset: offset, cellWidth: cellWidth,
                cellHeight: cellHeight, color: frameOverlay.linkUnderline)
            {
                let thickness = max(1, Float(scaleValue).rounded(.down))
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(quad.origin.x, quad.origin.y + cellHeight - thickness * 2),
                        size: .init(quad.size.x, thickness), color: quad.color))
            }
        }
        // A block cursor is drawn by its row (`appendRowInstances`).
        if cursorVisible, blockCursor == nil {
            let cellOrigin = SIMD2<Float>(
                Float(grid.cursor.column) * cellWidth, Float(grid.cursor.row) * cellHeight)
            // An eighth of a cell, at least 2 device pixels.
            let stroke = max(2, (cellHeight / 8).rounded(.down))
            let cursorColor = framePalette.cursor
            switch cursorStyle {
            case .block, .blinkingBlock:
                break  // Only off the live screen, where no cursor is drawn.
            case .underline, .blinkingUnderline:
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(cellOrigin.x, cellOrigin.y + cellHeight - stroke),
                        size: .init(cellWidth, stroke), color: cursorColor))
            case .bar, .blinkingBar:
                overlayScratch.append(
                    QuadInstance(
                        origin: cellOrigin, size: .init(stroke, cellHeight), color: cursorColor))
            }
        }
        let end = cachedBackground.count
        cachedBackground.replaceSubrange((end - overlayCount)..<end, with: overlayScratch)
        overlayCount = overlayScratch.count
    }

    /// The rule's column (`TerminalLayout.statusRuleOffset`, `Width`), in
    /// the inset — never over a cell. As tall as the grid.
    func markRect(beside rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - TerminalLayout.statusRuleOffset * scaleValue, y: rect.minY,
            width: TerminalLayout.statusRuleWidth * scaleValue, height: rect.height)
    }

    /// One rule per prompt row with an outcome, from the rows this frame
    /// draws: 2 points shorter than the row at each end, so neighbouring
    /// prompts' rules stay apart. An interruption is the rule split in two
    /// around its middle — a gap of 4 points.
    func rebuildMarks(alternateScreen: Bool) {
        cachedMarks.removeAll(keepingCapacity: true)
        guard drawsCommandMarks, !alternateScreen else { return }
        let cellHeight = Float(metricsValue.cellHeight)
        let point = Float(scaleValue)
        let width = Float(TerminalLayout.statusRuleWidth) * point
        // At least a point, however small the font.
        let height = max(point, cellHeight - 4 * point)
        for row in cachedLines.indices {
            let mark = cachedLines[row].mark
            guard mark.hasOutcome else { continue }
            let color = Self.markColor(mark, frameOverlay)
            let top = Float(row) * cellHeight + 2 * point
            if mark == .promptInterrupted {
                let half = max(point, height / 2 - 2 * point)
                cachedMarks.append(
                    QuadInstance(origin: .init(0, top), size: .init(width, half), color: color))
                cachedMarks.append(
                    QuadInstance(
                        origin: .init(0, top + height / 2 + 2 * point), size: .init(width, half),
                        color: color))
            } else {
                cachedMarks.append(
                    QuadInstance(origin: .init(0, top), size: .init(width, height), color: color))
            }
        }
    }

    /// Only an outcome is drawn (the caller's test). A prompt whose command
    /// has not reported — always the current one — and an output-start row
    /// carry nothing a reader can use, and after `clear` a grey rule on the
    /// lone prompt read as a rendering artefact (#165).
    private static func markColor(_ mark: LineMark, _ overlay: OverlayColors) -> SIMD4<Float> {
        if mark == .promptInterrupted { return overlay.markInterrupted }
        return mark == .promptFailed ? overlay.markFailed : overlay.markSucceeded
    }

    static func selectionsEqual(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.start == b.start && a.end == b.end
                && a.baseScrollbackTotal == b.baseScrollbackTotal
        default: return false
        }
    }

    /// Shifted by scrollback growth since recording, then by the scroll
    /// offset; rows off screen produce nothing.
    private func selectionQuads(
        _ selection: TerminalSelection, grid: Grid, offset: Int, cellWidth: Float, cellHeight: Float,
        color: SIMD4<Float>
    ) -> ContiguousArray<QuadInstance> {
        guard selection.start.row <= selection.end.row else { return [] }
        // `totalPushed`, as the copy path uses — `.count` let the highlight and
        // the copied text disagree once the ring filled.
        let firstRow =
            ScrollbackCoordinates.reanchoredRow(
                selection.start.row, from: selection.baseScrollbackTotal,
                to: grid.scrollback.totalPushed) + offset
        let lastRow =
            ScrollbackCoordinates.reanchoredRow(
                selection.end.row, from: selection.baseScrollbackTotal,
                to: grid.scrollback.totalPushed) + offset
        guard lastRow >= 0, firstRow < grid.rows else { return [] }
        var quads: ContiguousArray<QuadInstance> = []
        for row in max(0, firstRow)...min(grid.rows - 1, lastRow) {
            let startColumn =
                row == firstRow ? min(max(0, selection.start.column), grid.columns) : 0
            let endColumn =
                row == lastRow ? min(max(0, selection.end.column) + 1, grid.columns) : grid.columns
            guard endColumn > startColumn else { continue }
            quads.append(
                QuadInstance(
                    origin: .init(Float(startColumn) * cellWidth, Float(row) * cellHeight),
                    size: .init(Float(endColumn - startColumn) * cellWidth, cellHeight),
                    color: color))
        }
        return quads
    }
}
