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

import CortaTerminal
import Foundation

/// The damage-tracked row cache: which rows to rebuild, and moving retained rows instead of rebuilding them.
nonisolated extension TerminalRenderer {
    func rebuildAllRows(grid: Grid, offset: Int) {
        cachedBackground.removeAll(keepingCapacity: true)
        cachedGlyphs.removeAll(keepingCapacity: true)
        cachedColorGlyphs.removeAll(keepingCapacity: true)
        backgroundCounts.removeAll(keepingCapacity: true)
        glyphCounts.removeAll(keepingCapacity: true)
        colorGlyphCounts.removeAll(keepingCapacity: true)
        cachedLines.removeAll(keepingCapacity: true)
        cachedRevisions.removeAll(keepingCapacity: true)
        cachedBackground.reserveCapacity(grid.rows * grid.columns / 4 + 2)
        cachedGlyphs.reserveCapacity(grid.rows * grid.columns / 2)
        let liveScreen = offset == 0
        for row in 0..<grid.rows {
            let line = Self.visibleLine(grid: grid, row: row, offset: offset)
            let backgroundStart = cachedBackground.count
            let glyphStart = cachedGlyphs.count
            let colorGlyphStart = cachedColorGlyphs.count
            appendRowInstances(
                line: line, row: row, graphemes: grid.graphemes,
                background: &cachedBackground, glyphs: &cachedGlyphs,
                colorGlyphs: &cachedColorGlyphs)
            backgroundCounts.append(cachedBackground.count - backgroundStart)
            glyphCounts.append(cachedGlyphs.count - glyphStart)
            colorGlyphCounts.append(cachedColorGlyphs.count - colorGlyphStart)
            cachedLines.append(line)
            cachedRevisions.append(liveScreen ? grid.lineRevision(row) : 0)
        }
        overlayCount = 0
        invalidRows.removeAll(keepingCapacity: true)
        invalidRows.append(contentsOf: repeatElement(false, count: grid.rows))
        lastRebuiltRowCount = grid.rows
    }

    /// Line-granular damage: rebuild only the rows that changed into the
    /// scratch arrays, then put them in the cache (`place`), so a frame
    /// that damages every row costs one pass over the cache, not one per
    /// row.
    ///
    /// The live screen (`offset == 0`) is checked with `Grid.lineRevision`,
    /// a single `UInt64` compare, instead of a full `Line` comparison —
    /// see the type's doc comment and
    /// `ScreenLines.swift`. Scrolled into history, rows are immutable
    /// scrollback storage with no revision to compare. Retained history rows
    /// compare only their mutable mark; live/history transitions and the live
    /// portion of a partly scrolled viewport still compare cells by value.
    func rebuildDamagedRows(
        grid: Grid, offset: Int, previousBlockCursor: BlockCursor?
    ) -> Bool {
        let liveScreen = offset == 0
        let moved = shiftRetainedRows(grid: grid, offset: offset, previousBlockCursor: previousBlockCursor)
        forcedRowA = -1
        forcedRowB = -1
        if previousBlockCursor != blockCursor || moved.shifted {
            forcedRowA = moved.oldCursorRow
            forcedRowB = blockCursor?.row ?? -1
        }
        rowBackground.removeAll(keepingCapacity: true)
        rowGlyphs.removeAll(keepingCapacity: true)
        rowColorGlyphs.removeAll(keepingCapacity: true)
        rebuiltRows.removeAll(keepingCapacity: true)
        var backgroundStart = 0
        var glyphStart = 0
        var colorGlyphStart = 0
        for row in 0..<grid.rows {
            let revision = liveScreen ? grid.lineRevision(row) : 0
            let forced = row == forcedRowA || row == forcedRowB
            // Retained history cells never change; only marks can be edited.
            // A formerly live row may have changed before entering history,
            // so compare that transition by value rather than assuming it froze.
            let unchangedHistory = !liveScreen && row < offset && row < moved.retainedHistoryRows
                && !invalidRows[row]
                && grid.scrollback.mark(at: grid.scrollback.count - offset + row) == cachedLines[row].mark
            let possiblyChanged = forced || invalidRows[row]
                || (liveScreen ? revision != cachedRevisions[row] : !unchangedHistory)
            if possiblyChanged {
                let line = Self.visibleLine(grid: grid, row: row, offset: offset)
                if liveScreen || forced || invalidRows[row] || line != cachedLines[row] {
                    rebuildRow(
                        row, line: line, revision: revision, graphemes: grid.graphemes,
                        cachedStarts: (backgroundStart, glyphStart, colorGlyphStart))
                }
            }
            backgroundStart += backgroundCounts[row]
            glyphStart += glyphCounts[row]
            colorGlyphStart += colorGlyphCounts[row]
        }
        lastRebuiltRowCount = rebuiltRows.count
        guard !rebuiltRows.isEmpty else { return moved.shifted }
        place(
            into: &cachedBackground, counts: &backgroundCounts, from: rowBackground,
            ranges: \.background, starts: \.cachedBackgroundStart)
        place(
            into: &cachedGlyphs, counts: &glyphCounts, from: rowGlyphs, ranges: \.glyphs,
            starts: \.cachedGlyphStart)
        place(
            into: &cachedColorGlyphs, counts: &colorGlyphCounts, from: rowColorGlyphs,
            ranges: \.colorGlyphs, starts: \.cachedColorGlyphStart)
        return true
    }

    /// Moves the cached rows the way the screen moved since the last frame:
    /// the live screen replays the scroll journal, a viewport into history
    /// shifts by how far its document top moved. Returns where the old block
    /// cursor's row went (`-1` once it scrolled out) and how many retained
    /// history rows are still on screen.
    private func shiftRetainedRows(
        grid: Grid, offset: Int, previousBlockCursor: BlockCursor?
    ) -> (shifted: Bool, oldCursorRow: Int, retainedHistoryRows: Int) {
        var shifted = false
        var retainedHistoryRows = min(grid.rows, max(0, cachedOffset))
        var oldCursorRow = previousBlockCursor?.row ?? -1
        func shift(top: Int, bottom: Int, delta: Int) {
            applyShift(top: top, bottom: bottom, delta: delta, cellHeight: Float(metricsValue.cellHeight))
            shifted = true
            if oldCursorRow >= top && oldCursorRow <= bottom {
                oldCursorRow -= delta
                if oldCursorRow < top || oldCursorRow > bottom { oldCursorRow = -1 }
            }
        }
        if offset == 0 && cachedOffset == 0 {
            // Overflow: ordinary revision comparison remains correct; old cached
            // rows have not moved, so the old cursor also remains in its old row.
            guard grid.scrollEventsTotal >= cachedScrollEventsTotal,
                grid.scrollEventsTotal - cachedScrollEventsTotal <= UInt64(Grid.scrollEventCapacity)
            else { return (shifted, oldCursorRow, retainedHistoryRows) }
            // A region flood logs a line per event: same region, same
            // direction, the shifts add up, so each run moves once.
            var run: (top: Int, bottom: Int, delta: Int)?
            for sequence in cachedScrollEventsTotal..<grid.scrollEventsTotal {
                guard let event = grid.scrollEvent(at: sequence) else { continue }
                let next = (top: Int(event.top), bottom: Int(event.bottom), delta: Int(event.delta))
                if let pending = run, pending.top == next.top, pending.bottom == next.bottom,
                    (pending.delta > 0) == (next.delta > 0)
                {
                    run?.delta += next.delta
                    continue
                }
                if let pending = run { shift(top: pending.top, bottom: pending.bottom, delta: pending.delta) }
                run = next
            }
            if let pending = run { shift(top: pending.top, bottom: pending.bottom, delta: pending.delta) }
        } else {
            let delta = grid.scrollback.totalPushed - offset - cachedDocumentTop
            if delta != 0 {
                shift(top: 0, bottom: grid.rows - 1, delta: delta)
                retainedHistoryRows = max(0, min(grid.rows, retainedHistoryRows - delta))
            }
        }
        return (shifted, oldCursorRow, retainedHistoryRows)
    }

    /// Builds one row's instances into the scratch arrays and records where
    /// they go in the cache.
    private func rebuildRow(
        _ row: Int, line: Line, revision: UInt64, graphemes: GraphemeTable,
        cachedStarts: (background: Int, glyphs: Int, colorGlyphs: Int)
    ) {
        let starts = (rowBackground.count, rowGlyphs.count, rowColorGlyphs.count)
        appendRowInstances(
            line: line, row: row, graphemes: graphemes,
            background: &rowBackground, glyphs: &rowGlyphs, colorGlyphs: &rowColorGlyphs)
        rebuiltRows.append(
            RebuiltRow(
                row: row, background: starts.0..<rowBackground.count,
                glyphs: starts.1..<rowGlyphs.count, colorGlyphs: starts.2..<rowColorGlyphs.count,
                cachedBackgroundStart: cachedStarts.background, cachedGlyphStart: cachedStarts.glyphs,
                cachedColorGlyphStart: cachedStarts.colorGlyphs))
        cachedLines[row] = line
        cachedRevisions[row] = revision
        invalidRows[row] = false
    }

    /// Puts the rebuilt rows' instances from `scratch` into `cached`, the
    /// cheaper of two ways. In place, row by row, a row whose count changed
    /// moves everything after it — nothing for typing, the overlay alone for
    /// a scroll's new bottom row, but every instance once per row when a
    /// flood or a redrawing TUI changes them all. Past one array's worth of
    /// moves, the array is rebuilt in one pass instead: unchanged rows
    /// copied from the cache, rebuilt ones from `scratch`, then whatever
    /// follows the rows (the background's overlay). `counts` becomes the
    /// new per-row counts either way.
    private func place(
        into cached: inout ContiguousArray<QuadInstance>, counts: inout [Int], from scratch: ContiguousArray<QuadInstance>,
        ranges: KeyPath<RebuiltRow, Range<Int>>, starts: KeyPath<RebuiltRow, Int>
    ) {
        var moves = 0
        for rebuilt in rebuiltRows where rebuilt[keyPath: ranges].count != counts[rebuilt.row] {
            moves += cached.count - rebuilt[keyPath: starts] - counts[rebuilt.row]
        }
        if moves <= cached.count {
            var shift = 0
            for rebuilt in rebuiltRows {
                let range = rebuilt[keyPath: ranges]
                let start = rebuilt[keyPath: starts] + shift
                cached.replaceSubrange(start..<(start + counts[rebuilt.row]), with: scratch[range])
                shift += range.count - counts[rebuilt.row]
                counts[rebuilt.row] = range.count
            }
            return
        }
        spliceBuffer.removeAll(keepingCapacity: true)
        spliceBuffer.reserveCapacity(cached.count + scratch.count)
        var source = 0
        var next = 0
        for row in counts.indices {
            let count = counts[row]
            if next < rebuiltRows.count, rebuiltRows[next].row == row {
                let range = rebuiltRows[next][keyPath: ranges]
                spliceBuffer.append(contentsOf: scratch[range])
                counts[row] = range.count
                next += 1
            } else {
                spliceBuffer.append(contentsOf: cached[source..<(source + count)])
            }
            source += count
        }
        spliceBuffer.append(contentsOf: cached[source...])
        swap(&cached, &spliceBuffer)
    }

    /// Retained instances keep their atlas coordinates and move only in Y.
    /// Exposed rows are invalidated; overlays outside the region stay fixed.
    private func applyShift(top: Int, bottom: Int, delta: Int, cellHeight: Float) {
        guard delta != 0 else { return }
        let height = bottom - top + 1
        let count = min(abs(delta), height)
        let retained = delta > 0 ? (top + count)..<(bottom + 1) : top..<(bottom - count + 1)
        let shiftY = Float(delta) * cellHeight
        func moveInstances(_ instances: inout ContiguousArray<QuadInstance>, counts: inout [Int]) {
            let regionStart = counts[..<top].reduce(0, +)
            let regionEnd = regionStart + counts[top...bottom].reduce(0, +)
            let keptStart = counts[..<retained.lowerBound].reduce(0, +)
            let keptEnd = keptStart + counts[retained].reduce(0, +)
            // Delete the discarded ends in place. The overlay tail is outside
            // regionEnd and never moves in Y, even when its array index changes.
            instances.removeSubrange(keptEnd..<regionEnd)
            instances.removeSubrange(regionStart..<keptStart)
            for i in regionStart..<(regionStart + keptEnd - keptStart) {
                instances[i].origin.y -= shiftY
            }
            if delta > 0 {
                for row in top..<(bottom - count + 1) { counts[row] = counts[row + count] }
                for row in (bottom - count + 1)...bottom { counts[row] = 0 }
            } else {
                for row in stride(from: bottom, through: top + count, by: -1) { counts[row] = counts[row - count] }
                for row in top..<(top + count) { counts[row] = 0 }
            }
        }
        moveInstances(&cachedBackground, counts: &backgroundCounts)
        moveInstances(&cachedGlyphs, counts: &glyphCounts)
        moveInstances(&cachedColorGlyphs, counts: &colorGlyphCounts)
        if delta > 0 {
            for row in top..<(bottom - count + 1) {
                cachedLines[row] = cachedLines[row + count]
                cachedRevisions[row] = cachedRevisions[row + count]
                invalidRows[row] = invalidRows[row + count]
            }
        } else {
            for row in stride(from: bottom, through: top + count, by: -1) {
                cachedLines[row] = cachedLines[row - count]
                cachedRevisions[row] = cachedRevisions[row - count]
                invalidRows[row] = invalidRows[row - count]
            }
        }
        let exposed = delta > 0 ? (bottom - count + 1)...bottom : top...(top + count - 1)
        for row in exposed {
            cachedLines[row] = Line()
            cachedRevisions[row] = .max
            invalidRows[row] = true
        }
    }

    /// Scrollback and the live screen as one contiguous array.
    private static func visibleLine(grid: Grid, row: Int, offset: Int) -> Line {
        guard offset > 0 else { return grid.line(row) }
        let combinedIndex = grid.scrollback.count + row - offset
        if combinedIndex < grid.scrollback.count {
            return grid.scrollback[combinedIndex]
        }
        return grid.line(combinedIndex - grid.scrollback.count)
    }
}
