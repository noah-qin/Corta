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



extension Grid {
    // MARK: - Erasing

    public mutating func eraseLine(_ mode: LineEraseMode) {
        let template = pen.eraseCell
        switch mode {
        case .toEnd:
            // From a spacer: start one column earlier, or the lead is orphaned.
            var start = cursor.column
            if start > 0, lines[cursor.row][start].attributes.contains(.wideSpacer) {
                start -= 1
            }
            lines[cursor.row].erase(start..<columns, with: template)
            lines[cursor.row].wrapped = false
        case .toStart:
            var end = cursor.column + 1
            if end < columns, lines[cursor.row][cursor.column].attributes.contains(.wide) {
                end += 1
            }
            lines[cursor.row].erase(0..<end, with: template)
        case .all:
            lines[cursor.row].erase(0..<columns, with: template)
            lines[cursor.row].wrapped = false
        }
    }

    public mutating func eraseDisplay(_ mode: DisplayEraseMode) {
        let template = pen.eraseCell
        switch mode {
        case .toEnd:
            eraseLine(.toEnd)
            for row in (cursor.row + 1)..<rows {
                eraseWholeLine(row, with: template)
            }
        case .toStart:
            for row in 0..<cursor.row {
                eraseWholeLine(row, with: template)
            }
            eraseLine(.toStart)
        case .all:
            for row in 0..<rows {
                eraseWholeLine(row, with: template)
            }
            // The images go with the text they sat among (kitty's `ED 2`).
            imagePlacements.removePlacementsReachingScreen(
                scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        }
    }

    /// The mark goes with the prompt it sat beside: after `clear` a kept one
    /// was a coloured rule down an empty row (#165).
    private mutating func eraseWholeLine(_ row: Int, with template: Cell) {
        lines[row].mark = .none
        if template.isBlank {
            lines[row].clear()
        } else {
            lines[row].erase(0..<columns, with: template)
            lines[row].wrapped = false
        }
    }

    // MARK: - Scroll region

    /// DECSTBM: homes the cursor; a region under two rows is ignored.
    public mutating func setScrollRegion(top: Int, bottom: Int) {
        let top = max(0, top)
        let bottom = min(bottom, rows - 1)
        guard top < bottom else { return }
        marginTop = top
        marginBottom = bottom
        // Home is the region's top under DECOM.
        moveCursorAddressed(row: 0, column: 0)
    }

    // MARK: - Scrolling

    /// Rows reach scrollback only when the region is the whole screen — a
    /// partial region is an application's (tmux, vim), not history. `wrapped`
    /// travels with them (D03).
    public mutating func scrollUp(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        if marginTop == 0 && marginBottom == rows - 1 {
            if scrollback.limit > 0 {
                for row in 0..<count { scrollback.push(lines[row]) }
            } else {
                // No history (the alternate screen, `scrollback = 0`): no push
                // advances the image anchors, so move and clip them here.
                imagePlacements.scrollRegion(top: 0, bottom: rows - 1, delta: count,
                    scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
            }
            // The ring's O(count) rotation either way, not the region's O(rows).
            lines.rotateUp(count)
            return
        }
        imagePlacements.scrollRegion(top: marginTop, bottom: marginBottom, delta: count,
            scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        lines.rotate(top: marginTop, bottom: marginBottom, by: count)
    }

    /// SD: nothing enters scrollback — scrolling down creates no history.
    public mutating func scrollDown(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        imagePlacements.scrollRegion(top: marginTop, bottom: marginBottom, delta: -count,
            scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        lines.rotate(top: marginTop, bottom: marginBottom, by: -count)
    }

    // MARK: - Editing

    /// IL within the region; ignored outside it.
    public mutating func insertLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        shiftBand(by: -count)
        pendingWrap = false
    }

    /// DL within the region; deleted rows are never history.
    public mutating func deleteLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        shiftBand(by: count)
        pendingWrap = false
    }

    /// IL and DL are scrolls of the band from the cursor to the bottom margin:
    /// the same journaled rotation as SU/SD — the renderer shifts its cache
    /// instead of rebuilding every row below the cursor — and images wholly
    /// inside the band move with it. Exposed rows take the pen's background.
    private mutating func shiftBand(by delta: Int) {
        let top = cursor.row
        imagePlacements.scrollRegion(top: top, bottom: marginBottom, delta: delta,
            scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        lines.rotate(top: top, bottom: marginBottom, by: delta)
        let exposed = delta > 0 ? (marginBottom - delta + 1)...marginBottom : top...(top - delta - 1)
        let erased = erasedLine()
        for row in exposed { lines[row] = erased }
    }

    public mutating func insertCharacters(_ count: Int) {
        insertBlankCells(count, row: cursor.row, column: cursor.column)
        pendingWrap = false
    }

    public mutating func deleteCharacters(_ count: Int) {
        lines[cursor.row].deleteCells(count, at: cursor.column, template: pen.eraseCell, width: columns)
        repairWidePairs(row: cursor.row, template: pen.eraseCell)
        pendingWrap = false
    }

    /// ECH: erases in place, nothing shifts; zero erases one, as xterm does.
    /// tmux draws its status line around an ECH gap.
    public mutating func eraseCharacters(_ count: Int) {
        let start = cursor.column
        guard start < columns else { return }
        let end = min(columns, start + max(1, count))
        let template = pen.eraseCell
        lines[cursor.row].erase(start..<end, with: template)
        // A wide pair cut on either edge of the range is half-erased;
        // the survivor is not a glyph and is erased too.
        repairWidePairs(row: cursor.row, template: template)
        pendingWrap = false
    }

    /// With BCE, an erased cell under a colour is stored.
    private func erasedLine() -> Line {
        let template = pen.eraseCell
        guard !template.isBlank else { return Line() }
        var line = Line()
        line.fill(template, in: 0..<columns)
        return line
    }
}
