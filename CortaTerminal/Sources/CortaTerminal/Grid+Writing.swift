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
    // MARK: - Writing

    /// Advances by the scalar's display width (0, 1 or 2).
    public mutating func write(_ scalar: UInt32) {
        // Printable ASCII: width 1, never a control — no lookup. Runs per byte.
        if scalar >= 0x20, scalar < 0x7F {
            writeNarrow(scalar)
            return
        }
        // A control has width 0 and would corrupt the combining path.
        guard let value = Unicode.Scalar(scalar), !Self.isControl(value) else { return }
        // Drawn, not folded invisibly into the previous cell: invisible is
        // what makes a bidi override or a hidden ZWSP work (`SECURITY.md` §2.5).
        if ConcealingScalars.contains(scalar), !continuesFlagTagSequence(scalar) {
            writeNarrow(UTF8Decoder.replacement)
            return
        }
        // After a ZWJ, the scalar continues the cluster: an emoji ZWJ sequence
        // is one wide cell, not a pair per emoji.
        if scalar != 0x200D, let target = clusterJoinTarget(), clusterEndsWithZWJ(target) {
            combine(scalar, row: target.row, column: target.column)
            return
        }
        // A flag is two regional indicators and one grapheme (UAX #29); without
        // this it takes four columns and every border after it lands late.
        if Self.isRegionalIndicator(scalar), let target = clusterJoinTarget(),
            endsWithLoneRegionalIndicator(target)
        {
            combine(scalar, row: target.row, column: target.column)
            return
        }
        switch displayWidth(of: value) {
        case 0:
            writeZeroWidth(scalar)
        case 2 where columns >= 2:
            writeWide(scalar)
        default:
            // A one-column screen cannot hold a pair; the wide scalar falls
            // back to a single cramped cell rather than vanishing.
            writeNarrow(scalar)
        }
    }

    /// A ground-state ASCII run, already validated by the parser.
    public mutating func writeASCII(_ bytes: ArraySlice<UInt8>) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if pendingWrap {
                lines[cursor.row].wrapped = true
                cursor.column = 0
                lineFeedWithoutClearingWrap()
            }
            let available = columns - cursor.column
            var count = min(available, bytes.distance(from: index, to: bytes.endIndex))
            if !autowrapEnabled, count == available, available < bytes.distance(from: index, to: bytes.endIndex) {
                // Nothing wraps: everything past the margin lands on the last
                // column in turn, so the run's last byte is what stays there.
                count -= 1
                if count > 0 {
                    if insertMode { insertBlankCells(count, row: cursor.row, column: cursor.column) }
                    lines[cursor.row].overwriteASCII(
                        bytes[index..<bytes.index(index, offsetBy: count)], at: cursor.column, pen: pen)
                }
                cursor.column = columns - 1
                writeNarrow(UInt32(bytes[bytes.index(before: bytes.endIndex)]))
                return
            }
            let end = bytes.index(index, offsetBy: count)
            // Insert mode shifts once per chunk, not per character.
            if insertMode { insertBlankCells(count, row: cursor.row, column: cursor.column) }
            lines[cursor.row].overwriteASCII(bytes[index..<end], at: cursor.column, pen: pen)
            if cursor.column + count >= columns {
                cursor.column = columns - 1
                pendingWrap = autowrapEnabled
            } else {
                cursor.column += count
                pendingWrap = false
            }
            index = end
        }
    }

    /// A tag continuing a cluster that starts with U+1F3F4: a subdivision flag.
    private func continuesFlagTagSequence(_ scalar: UInt32) -> Bool {
        guard ConcealingScalars.isTag(scalar), let target = clusterJoinTarget() else { return false }
        let cell = lines[target.row][target.column]
        let cluster = graphemes.scalars(for: cell.grapheme) ?? [cell.scalar]
        return ConcealingScalars.continuesFlag(cluster, with: scalar)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private mutating func writeNarrow(_ scalar: UInt32) {
        if pendingWrap {
            // The row really did continue onto the next one. This is the
            // only place `wrapped` is ever set (`DECISIONS.md` D03).
            lines[cursor.row].wrapped = true
            cursor.column = 0
            lineFeedWithoutClearingWrap()
        }
        if insertMode { insertBlankCells(1, row: cursor.row, column: cursor.column) }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        lines[cursor.row][cursor.column] = pen.cell(scalar)
        if cursor.column + 1 >= columns {
            pendingWrap = autowrapEnabled
        } else {
            cursor.column += 1
            pendingWrap = false
        }
    }

    /// Width 2: a `.wide` lead plus a blank `.wideSpacer`.
    private mutating func writeWide(_ scalar: UInt32) {
        // Without autowrap a pair cannot move to the next row, and half of
        // one is not a character: it is not written.
        if !autowrapEnabled, cursor.column == columns - 1 { return }
        if !pendingWrap, cursor.column == columns - 1 {
            // A pair may not straddle the margin: blank the last column and wrap
            // (as xterm does).
            blankWidePairHalves(row: cursor.row, column: cursor.column)
            lines[cursor.row][cursor.column] = pen.eraseCell
            pendingWrap = true
        }
        if pendingWrap {
            lines[cursor.row].wrapped = true
            cursor.column = 0
            lineFeedWithoutClearingWrap()
        }
        // Make room for both columns, or the second overwrites what shifted.
        if insertMode { insertBlankCells(2, row: cursor.row, column: cursor.column) }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        // The spacer may land on the lead of a later pair; blank it too.
        blankWidePairHalves(row: cursor.row, column: cursor.column + 1)
        var lead = pen.cell(scalar)
        lead.attributes.insert(.wide)
        var spacer = pen.cell(0x20)
        spacer.attributes.insert(.wideSpacer)
        lines[cursor.row].overwriteWide(lead, spacer: spacer, at: cursor.column)
        if cursor.column + 2 >= columns {
            // The pair ended in the last column: the cursor rests on the
            // spacer with the wrap armed, exactly as a narrow write does.
            cursor.column = columns - 1
            pendingWrap = autowrapEnabled
        } else {
            cursor.column += 2
            pendingWrap = false
        }
    }

    /// Width 0: joins the previous cell's cluster; the cursor stays.
    private mutating func writeZeroWidth(_ scalar: UInt32) {
        guard let target = clusterJoinTarget() else {
            // No previous cell: keep the mark as a base character, as xterm does.
            writeNarrow(scalar)
            return
        }
        combine(scalar, row: target.row, column: target.column)
        if scalar == 0xFE0F { widenEmojiPresentation(at: target) }
    }

    /// VS16 changes a standardized text-default emoji from one to two cells.
    /// The selector itself remains zero-width; all later output sees the new
    /// cursor position, including when the cluster moves across the margin.
    private mutating func widenEmojiPresentation(at target: (row: Int, column: Int)) {
        var lead = lines[target.row][target.column]
        guard columns >= 2, !lead.attributes.contains(.wide),
              supportsEmojiPresentation(lead.scalar),
              let cluster = graphemes.scalars(for: lead.grapheme), cluster.count == 2, cluster.last == 0xFE0F
        else { return }
        lead.attributes.insert(.wide)
        if target.column == columns - 1 {
            // Moving the pair to the next row is a wrap.
            guard autowrapEnabled else { return }
            lines[target.row][target.column] = pen.eraseCell
            cursor.row = target.row
            cursor.column = target.column
            pendingWrap = true
            writeWide(lead.scalar)
            if let moved = clusterJoinTarget() { lines[moved.row][moved.column] = lead }
            return
        }
        if insertMode { insertBlankCells(1, row: target.row, column: target.column + 1) }
        blankWidePairHalves(row: target.row, column: target.column + 1)
        var spacer = lead
        spacer.scalar = 0x20
        spacer.grapheme = .none
        spacer.attributes.remove(.wide)
        spacer.attributes.insert(.wideSpacer)
        lines[target.row][target.column] = lead
        lines[target.row][target.column + 1] = spacer
        if cursor.row == target.row {
            if target.column + 2 >= columns {
                cursor.column = columns - 1
                pendingWrap = autowrapEnabled
            } else {
                cursor.column = target.column + 2
            }
        }
    }

    /// The previously written cell, following wraps and wide pairs; `nil`
    /// at the start of output or after a hard newline.
    private func clusterJoinTarget() -> (row: Int, column: Int)? {
        var row = cursor.row
        var column: Int
        if pendingWrap {
            // The cursor rests on the last column, which is the last write.
            column = cursor.column
        } else if cursor.column > 0 {
            column = cursor.column - 1
        } else if cursor.row > 0, lines[cursor.row - 1].wrapped {
            // The logical line continues from the wrapped row above.
            row = cursor.row - 1
            column = columns - 1
        } else {
            return nil
        }
        // A mark after a wide pair belongs to the pair's lead cell.
        if column > 0, lines[row][column].attributes.contains(.wideSpacer) {
            column -= 1
        }
        return (row, column)
    }

    /// Plain cells answer without a table lookup, so CJK pays a bounds check.
    /// A full cluster (`GraphemeTable.maximumClusterScalars`) continues
    /// nothing: the next character starts its own cell. Joined instead, it
    /// would be dropped at the cap, and so would every character after it.
    private func clusterEndsWithZWJ(_ target: (row: Int, column: Int)) -> Bool {
        let cell = lines[target.row][target.column]
        guard !cell.grapheme.isNone, let cluster = graphemes.scalars(for: cell.grapheme),
            cluster.count < GraphemeTable.maximumClusterScalars
        else { return false }
        return cluster.last == 0x200D
    }

    private static func isRegionalIndicator(_ scalar: UInt32) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar)
    }

    /// An *unpaired* regional indicator: an odd trailing run is waiting for
    /// its pair; an even one is a finished flag.
    private func endsWithLoneRegionalIndicator(_ target: (row: Int, column: Int)) -> Bool {
        let cell = lines[target.row][target.column]
        guard !cell.grapheme.isNone, let cluster = graphemes.scalars(for: cell.grapheme) else {
            return Self.isRegionalIndicator(cell.scalar)
        }
        // Full: as for a ZWJ, the next indicator starts its own cell.
        guard cluster.count < GraphemeTable.maximumClusterScalars else { return false }
        var trailing = 0
        for scalar in cluster.reversed() {
            guard Self.isRegionalIndicator(scalar) else { break }
            trailing += 1
        }
        return trailing % 2 == 1
    }

    private mutating func combine(_ scalar: UInt32, row: Int, column: Int) {
        let cell = lines[row][column]
        // Past the cap the mark is dropped, as when the table is full.
        if let cluster = graphemes.scalars(for: cell.grapheme),
            cluster.count >= GraphemeTable.maximumClusterScalars
        { return }
        var id = graphemes.intern(extending: cell.grapheme, base: cell.scalar, with: scalar)
        if id == nil, graphemes.count >= GraphemeTable.capacity,
            Self.sideTableSweepAllowed(&graphemeSweepDeferral)
        {
            // Full: sweep, retry once; still full means the mark is dropped.
            sideTableSweeps += 1
            let freed = graphemes.reclaim(keeping: liveGraphemeIDs())
            Self.deferSideTableSweep(&graphemeSweepDeferral, freed: freed, capacity: GraphemeTable.capacity)
            id = graphemes.intern(extending: cell.grapheme, base: cell.scalar, with: scalar)
        }
        guard let id else { return }
        var updated = cell
        updated.grapheme = id
        lines[row][column] = updated
    }

    /// Touching either half of a wide pair blanks both; a lone half draws as
    /// a stray glyph.
    private mutating func blankWidePairHalves(row: Int, column: Int) {
        let cell = lines[row][column]
        if cell.attributes.contains(.wideSpacer), column > 0 {
            lines[row][column - 1] = pen.eraseCell
        } else if cell.attributes.contains(.wide), column + 1 < columns {
            lines[row][column + 1] = pen.eraseCell
        }
    }

    /// IRM's shift. A pair pushed against the margin loses its spacer, and an
    /// insert between a lead and its spacer parts them; either orphan made the
    /// next column-changing reflow read past the end of its row.
    mutating func insertBlankCells(_ count: Int, row: Int, column: Int) {
        let template = pen.eraseCell
        lines[row].insertCells(count, at: column, template: template, width: columns)
        repairWidePairs(row: row, template: template)
    }

    /// After ICH/DCH, blanks every half that lost its partner.
    mutating func repairWidePairs(row: Int, template: Cell) {
        var column = 0
        while column < lines[row].count {
            let cell = lines[row][column]
            if cell.attributes.contains(.wide) {
                let intact =
                    column + 1 < columns
                    && lines[row][column + 1].attributes.contains(.wideSpacer)
                if !intact { lines[row][column] = template }
            } else if cell.attributes.contains(.wideSpacer) {
                let intact =
                    column > 0
                    && lines[row][column - 1].attributes.contains(.wide)
                if !intact { lines[row][column] = template }
            }
            column += 1
        }
    }
}
