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

public struct Cursor: Equatable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int = 0, column: Int = 0) {
        self.row = row
        self.column = column
    }
}

/// DECSCUSR (xterm ctlseqs, `CSI Ps SP q`): the cursor's shape and blink.
/// The core stores it; drawing it is the renderer's concern.
public enum CursorStyle: Equatable, Sendable {
    case blinkingBlock
    case block
    case blinkingUnderline
    case underline
    case blinkingBar
    case bar
}

public enum LineEraseMode: Sendable {
    /// EL 0 — the cursor and everything right of it.
    case toEnd
    /// EL 1 — everything left of the cursor, and the cursor.
    case toStart
    /// EL 2 — the whole row.
    case all
}

public enum DisplayEraseMode: Sendable {
    /// ED 0 — the cursor to the end of the screen.
    case toEnd
    /// ED 1 — the start of the screen to the cursor.
    case toStart
    /// ED 2 — the whole screen.
    case all
}

/// The visible screen: cells, a cursor, the pen. It knows no escape
/// sequences — `Performer` decides what `ESC [ 2 J` means — so each is
/// testable without the other.
public struct Grid: Sendable {
    /// Sanity bounds. A window cannot be this large; a hostile resize
    /// request or a corrupt parameter can ask for it (`SECURITY.md` §3).
    public static let maxRows = 4096
    public static let maxColumns = 4096

    public internal(set) var rows: Int
    public internal(set) var columns: Int
    internal var lines: ScreenLines

    public var cursor: Cursor
    public var pen: Pen
    private var tabStops: ContiguousArray<Bool>

    /// DECSCUSR state (xterm ctlseqs). Global to the terminal rather than
    /// per screen: it survives an alternate-screen round trip.
    public var cursorStyle: CursorStyle = .blinkingBlock

    /// Grapheme clusters too large for a cell's single scalar
    /// (`DECISIONS.md` D05): combining-mark clusters and emoji ZWJ sequences.
    public var graphemes: GraphemeTable

    /// OSC 8 targets. Never cleared while an id may be on screen or in
    /// scrollback; unreferenced entries are swept under pressure
    /// (`internHyperlink`).
    public var hyperlinks: HyperlinkTable

    /// Failed interns left before the next futile sweep may run
    /// (`internHyperlink`, `combine`).
    private var hyperlinkSweepDeferral = 0
    private var graphemeSweepDeferral = 0
    /// Full-grid scans run by the two sweeps, for tests.
    private(set) var sideTableSweeps = 0

    /// Cleared on a column resize, kept across a row-only one.
    public var imagePlacements = ImagePlacementTable()
    /// The pty's pixel height per row (`ws_ypixel / ws_row`), which the app
    /// reports and clients such as `kitten icat` size images by; 0 until one
    /// arrives. Erasing the display reads it, to tell whether an image with
    /// no `r=` reaches the visible screen, and so does placing one, to move
    /// the cursor past it.
    public var cellPixelHeight = 0
    /// The pty's pixel width per column (`ws_xpixel / ws_col`); 0 until one
    /// arrives. Only placing an image with no `c=` reads it.
    public var cellPixelWidth = 0

    public var scrollback: Scrollback

    /// IRM: a printed character inserts, pushing the row right. Implemented,
    /// not merely reported — `readline`'s and `ed`'s insert paths use it.
    public var insertMode: Bool = false

    /// `?45` reverse wraparound: `BS`/`CUB` past column 0 continue onto the row
    /// above only across an auto-wrap, never a hard newline. Off by default, as
    /// in xterm.
    public var reverseWraparoundEnabled: Bool = false

    /// Deferred wrap: printing into the last column arms this; the next
    /// character wraps first. Otherwise filling the last column and moving the
    /// cursor would scroll the screen.
    public internal(set) var pendingWrap: Bool

    /// DECSC's slot — cursor, pen and wrap state (VT510 §DECSC).
    private var savedCursor: Cursor?
    private var savedPen: Pen?
    private var savedPendingWrap: Bool = false

    /// True while the alternate screen is live.
    public private(set) var isAlternateScreenActive: Bool = false

    private var suspendedMain: SuspendedScreen?

    /// DECSTBM, zero-based and inclusive.
    public private(set) var marginTop: Int = 0
    public private(set) var marginBottom: Int

    public init(rows: Int = 24, columns: Int = 80, scrollbackLimit: Int = Scrollback.defaultLimit) {
        self.rows = min(max(1, rows), Self.maxRows)
        self.columns = min(max(1, columns), Self.maxColumns)
        self.lines = ScreenLines(repeating: Line(), count: self.rows)
        self.cursor = Cursor()
        self.pen = Pen()
        self.tabStops = Self.defaultTabStops(columns: self.columns)
        self.cursorStyle = .blinkingBlock
        self.graphemes = GraphemeTable()
        self.hyperlinks = HyperlinkTable()
        self.scrollback = Scrollback(limit: scrollbackLimit)
        self.pendingWrap = false
        self.savedCursor = nil
        self.savedPen = nil
        self.savedPendingWrap = false
        self.isAlternateScreenActive = false
        self.suspendedMain = nil
        self.marginBottom = self.rows - 1
    }

    // MARK: - Reading

    public subscript(row: Int, column: Int) -> Cell {
        @inline(__always)
        get {
            guard row >= 0, row < rows else { return .blank }
            return lines[row][column]
        }
    }

    public func line(_ row: Int) -> Line {
        guard row >= 0, row < rows else { return Line() }
        return lines[row]
    }

    /// A cheap "possibly changed" stamp for damage tracking; out of range is
    /// `0`, which a renderer with no cache already treats as different.
    public func lineRevision(_ row: Int) -> UInt64 {
        guard row >= 0, row < rows else { return 0 }
        return lines.revision(at: row)
    }

    /// Changes when a fresh `ScreenLines` is swapped in (alternate screen, column
    /// resize), whose revisions restart from zero.
    public var linesGeneration: UInt64 { lines.generation }

    public var linesRotated: UInt64 { lines.totalRotated }

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
            let count = min(available, bytes.distance(from: index, to: bytes.endIndex))
            let end = bytes.index(index, offsetBy: count)
            // Insert mode shifts once per chunk, not per character.
            if insertMode {
                lines[cursor.row].insertCells(
                    count, at: cursor.column, template: pen.eraseCell, width: columns)
            }
            lines[cursor.row].overwriteASCII(bytes[index..<end], at: cursor.column, pen: pen)
            if cursor.column + count >= columns {
                cursor.column = columns - 1
                pendingWrap = true
            } else {
                cursor.column += count
                pendingWrap = false
            }
            index = end
        }
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
        if insertMode {
            lines[cursor.row].insertCells(
                1, at: cursor.column, template: pen.eraseCell, width: columns)
        }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        lines[cursor.row][cursor.column] = pen.cell(scalar)
        if cursor.column + 1 >= columns {
            pendingWrap = true
        } else {
            cursor.column += 1
            pendingWrap = false
        }
    }

    /// Width 2: a `.wide` lead plus a blank `.wideSpacer`.
    private mutating func writeWide(_ scalar: UInt32) {
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
        if insertMode {
            // Make room for both columns, or the second overwrites what shifted.
            lines[cursor.row].insertCells(
                2, at: cursor.column, template: pen.eraseCell, width: columns)
        }
        blankWidePairHalves(row: cursor.row, column: cursor.column)
        // The spacer may land on the lead of a later pair; blank it too.
        blankWidePairHalves(row: cursor.row, column: cursor.column + 1)
        var lead = pen.cell(scalar)
        lead.attributes.insert(.wide)
        var spacer = pen.cell(0x20)
        spacer.attributes.insert(.wideSpacer)
        lines[cursor.row][cursor.column] = lead
        lines[cursor.row][cursor.column + 1] = spacer
        if cursor.column + 2 >= columns {
            // The pair ended in the last column: the cursor rests on the
            // spacer with the wrap armed, exactly as a narrow write does.
            cursor.column = columns - 1
            pendingWrap = true
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
    private func clusterEndsWithZWJ(_ target: (row: Int, column: Int)) -> Bool {
        let cell = lines[target.row][target.column]
        guard !cell.grapheme.isNone else { return false }
        return graphemes.scalars(for: cell.grapheme)?.last == 0x200D
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
        var trailing = 0
        for scalar in cluster.reversed() {
            guard Self.isRegionalIndicator(scalar) else { break }
            trailing += 1
        }
        return trailing % 2 == 1
    }

    private mutating func combine(_ scalar: UInt32, row: Int, column: Int) {
        let cell = lines[row][column]
        var cluster = graphemes.scalars(for: cell.grapheme) ?? [cell.scalar]
        // Past the cap the mark is dropped, as when the table is full.
        guard cluster.count < GraphemeTable.maximumClusterScalars else { return }
        cluster.append(scalar)
        var id = graphemes.intern(cluster)
        if id == nil, graphemes.count >= GraphemeTable.capacity,
            Self.sideTableSweepAllowed(&graphemeSweepDeferral)
        {
            // Full: sweep, retry once; still full means the mark is dropped.
            sideTableSweeps += 1
            let freed = graphemes.reclaim(keeping: liveGraphemeIDs())
            Self.deferSideTableSweep(&graphemeSweepDeferral, freed: freed, capacity: GraphemeTable.capacity)
            id = graphemes.intern(cluster)
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

    /// After ICH/DCH, blanks every half that lost its partner.
    private mutating func repairWidePairs(row: Int, template: Cell) {
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

    // MARK: - Cursor movement

    /// Zero-based and clamped.
    public mutating func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(0, row), rows - 1)
        cursor.column = min(max(0, column), columns - 1)
        pendingWrap = false
    }

    public mutating func moveCursorUp(_ count: Int = 1) {
        let floor = (marginTop...marginBottom).contains(cursor.row) ? marginTop : 0
        moveCursor(row: max(floor, cursor.row - max(0, count)), column: cursor.column)
    }

    public mutating func moveCursorDown(_ count: Int = 1) {
        let ceiling = (marginTop...marginBottom).contains(cursor.row) ? marginBottom : rows - 1
        moveCursor(row: min(ceiling, cursor.row + max(0, count)), column: cursor.column)
    }

    /// Clamps at column 0 unless `?45` lets it cross auto-wrapped rows.
    public mutating func moveCursorLeft(_ count: Int = 1) {
        guard reverseWraparoundEnabled else {
            moveCursor(row: cursor.row, column: cursor.column - max(0, count))
            return
        }
        var remaining = max(0, count)
        while remaining > 0 {
            if cursor.column > 0 {
                cursor.column -= 1
                remaining -= 1
            } else if cursor.row > 0, lines[cursor.row - 1].wrapped {
                cursor.row -= 1
                cursor.column = columns - 1
                remaining -= 1
            } else {
                break
            }
        }
        pendingWrap = false
    }

    public mutating func moveCursorRight(_ count: Int = 1) {
        moveCursor(row: cursor.row, column: cursor.column + max(0, count))
    }

    public mutating func moveToNextLine(_ count: Int = 1) {
        moveCursor(row: cursor.row + max(1, count), column: 0)
    }

    public mutating func moveToPreviousLine(_ count: Int = 1) {
        moveCursor(row: cursor.row - max(1, count), column: 0)
    }

    public mutating func carriageReturn() {
        cursor.column = 0
        pendingWrap = false
    }

    /// Like CUB by one. Out of an armed wrap it disarms rather than moves, which
    /// keeps `printf 'x%80s'; printf '\b'` on the row.
    public mutating func backspace() {
        if pendingWrap {
            pendingWrap = false
            return
        }
        if cursor.column > 0 {
            cursor.column -= 1
        } else if reverseWraparoundEnabled, cursor.row > 0, lines[cursor.row - 1].wrapped {
            cursor.row -= 1
            cursor.column = columns - 1
        }
    }

    /// HT — the next tab stop. Stops start every eight columns; HTS and TBC
    /// change them (`setTabStop`, `clearTabStop`).
    public mutating func tab() {
        tabForward(1)
    }

    public mutating func tabForward(_ count: Int) {
        for _ in 0..<max(1, count) {
            var next = cursor.column + 1
            while next < columns - 1, !tabStops[next] { next += 1 }
            cursor.column = min(next, columns - 1)
        }
        pendingWrap = false
    }

    public mutating func tabBackward(_ count: Int) {
        for _ in 0..<max(1, count) {
            var previous = cursor.column - 1
            while previous > 0, !tabStops[previous] { previous -= 1 }
            cursor.column = max(previous, 0)
        }
        pendingWrap = false
    }

    public static let tabInterval = 8

    public mutating func resetToInitialState() {
        let cellPixelHeight = cellPixelHeight
        let cellPixelWidth = cellPixelWidth
        self = Grid(rows: rows, columns: columns, scrollbackLimit: scrollback.limit)
        self.cellPixelHeight = cellPixelHeight
        self.cellPixelWidth = cellPixelWidth
    }

    /// Erases the screen and homes the cursor, keeping the scrollback. Not
    /// `ED 2` alone (the cursor stays mid-screen) and not a scroll into history
    /// (which makes "clear" and "keep history" the same thing).
    public mutating func clearScreen() {
        eraseDisplay(.all)
        cursor = Cursor(row: 0, column: 0)
        pendingWrap = false
    }

    /// Discards the scrollback, screen untouched — after pasting a secret —
    /// and the images wholly in it (`ED 3`).
    public mutating func clearScrollback() {
        imagePlacements.removePlacementsWhollyInScrollback(
            scrollbackTotal: scrollback.totalPushed, cellPixelHeight: cellPixelHeight)
        scrollback.removeAll()
    }

    /// DECSTR (soft reset) resets modes without erasing the display or
    /// moving the active cursor.
    public mutating func softReset() {
        marginTop = 0
        marginBottom = rows - 1
        pen.reset()
        pendingWrap = false
        savedCursor = Cursor()
        savedPen = Pen()
        savedPendingWrap = false
        cursorStyle = .blinkingBlock
    }

    /// DECALN: `E` everywhere, margins reset, cursor home, in the default pen.
    /// esctest uses it to reach a known state before every check, so ignoring it
    /// voids every test built on it.
    public mutating func alignmentDisplay() {
        marginTop = 0
        marginBottom = rows - 1
        pen.reset()
        pendingWrap = false
        cursor = Cursor(row: 0, column: 0)
        for _ in 0..<rows {
            for _ in 0..<columns {
                write(UInt32(UInt8(ascii: "E")))
            }
            pendingWrap = false
            if cursor.row < rows - 1 {
                cursor = Cursor(row: cursor.row + 1, column: 0)
            }
        }
        cursor = Cursor(row: 0, column: 0)
        pendingWrap = false
    }

    public mutating func setTabStop() {
        tabStops[cursor.column] = true
    }

    public mutating func clearTabStop(atCursorOnly: Bool) {
        if atCursorOnly {
            tabStops[cursor.column] = false
        } else {
            for index in tabStops.indices { tabStops[index] = false }
        }
    }

    private static func defaultTabStops(columns: Int) -> ContiguousArray<Bool> {
        ContiguousArray((0..<columns).map { $0 > 0 && $0 % tabInterval == 0 })
    }

    private mutating func resizeTabStops(to newColumns: Int) {
        if newColumns < tabStops.count {
            tabStops.removeLast(tabStops.count - newColumns)
        } else if newColumns > tabStops.count {
            let oldCount = tabStops.count
            tabStops.append(contentsOf: repeatElement(false, count: newColumns - oldCount))
            for column in oldCount..<newColumns where column > 0 && column % Self.tabInterval == 0 {
                tabStops[column] = true
            }
        }
    }

    /// LF, VT, FF: down one row; the column is CR's job.
    public mutating func lineFeed() {
        lineFeedWithoutClearingWrap()
        pendingWrap = false
    }

    public mutating func reverseIndex() {
        if cursor.row == marginTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
        pendingWrap = false
    }

    private mutating func lineFeedWithoutClearingWrap() {
        if cursor.row == marginBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    // MARK: - Side-table reclamation

    /// Sweeps unreferenced entries when full; without it a session that met
    /// `capacity` URLs would never link again.
    public mutating func internHyperlink(_ url: String) -> HyperlinkID? {
        if let id = hyperlinks.intern(url) { return id }
        guard hyperlinks.count >= HyperlinkTable.capacity,
            Self.sideTableSweepAllowed(&hyperlinkSweepDeferral)
        else { return nil }
        sideTableSweeps += 1
        let freed = hyperlinks.reclaim(keeping: liveHyperlinkIDs())
        Self.deferSideTableSweep(&hyperlinkSweepDeferral, freed: freed, capacity: HyperlinkTable.capacity)
        return hyperlinks.intern(url)
    }

    /// A sweep scans every cell on screen and in scrollback under the session
    /// lock. When the table is full of entries still in use it frees nothing,
    /// and sweeping again on every new link or mark — `ls --hyperlink -R`
    /// over a big tree — froze the pane. So a sweep that freed under a quarter
    /// of the table skips the next quarter-table's worth of failed interns:
    /// at most one scan per that many, and what fails meanwhile goes unlinked
    /// or unmarked, as when full.
    private static func sideTableSweepAllowed(_ deferral: inout Int) -> Bool {
        guard deferral > 0 else { return true }
        deferral -= 1
        return false
    }

    private static func deferSideTableSweep(_ deferral: inout Int, freed: Int, capacity: Int) {
        let quarter = capacity / 4
        deferral = freed < quarter ? quarter : 0
    }

    /// Cells on screen and in scrollback, plus both pens (a saved pen restores
    /// into the current one). The parked main screen and snapshots hold their
    /// own copy of the table, so scanning only this value is reference-safe.
    func liveHyperlinkIDs() -> Set<HyperlinkID> {
        var live: Set<HyperlinkID> = [pen.hyperlink]
        if let savedPen { live.insert(savedPen.hyperlink) }
        for row in 0..<rows {
            for cell in lines[row].cells where !cell.hyperlink.isNone {
                live.insert(cell.hyperlink)
            }
        }
        for index in 0..<scrollback.count {
            for cell in scrollback[index].cells where !cell.hyperlink.isNone {
                live.insert(cell.hyperlink)
            }
        }
        live.remove(.none)
        return live
    }

    /// Cells only: no pen carries a cluster.
    func liveGraphemeIDs() -> Set<GraphemeID> {
        var live: Set<GraphemeID> = []
        for row in 0..<rows {
            for cell in lines[row].cells where !cell.grapheme.isNone {
                live.insert(cell.grapheme)
            }
        }
        for index in 0..<scrollback.count {
            for cell in scrollback[index].cells where !cell.grapheme.isNone {
                live.insert(cell.grapheme)
            }
        }
        return live
    }

    /// Tests only; in production each table sweeps when `intern` is full.
    mutating func compactSideTables() {
        graphemes.reclaim(keeping: liveGraphemeIDs())
        hyperlinks.reclaim(keeping: liveHyperlinkIDs())
    }

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

    // MARK: - Resizing

    /// A column change reflows (D03), except on the alternate screen: the
    /// program redraws on `SIGWINCH`, and re-wrapping would corrupt its model.
    /// A row-only change moves rows to or from scrollback.
    public mutating func resize(rows newRows: Int, columns newColumns: Int) {
        let newRows = min(max(1, newRows), Self.maxRows)
        let newColumns = min(max(1, newColumns), Self.maxColumns)
        guard newRows != rows || newColumns != columns else { return }

        // Exact cell coordinates a column change invalidates.
        if newColumns != columns {
            imagePlacements.removeAllPlacements()
        }

        if newColumns != columns, !isAlternateScreenActive {
            resizeTabStops(to: newColumns)
            reflow(toColumns: newColumns, newRows: newRows)
            rows = newRows
            marginTop = min(marginTop, rows - 1)
            marginBottom = min(marginBottom, rows - 1)
            if marginTop >= marginBottom {
                marginTop = 0
                marginBottom = rows - 1
            }
            return
        }

        if newRows < rows {
            // Off the top, into scrollback: the bottom holds the cursor and the
            // newest output, and truncating there loses the last commands silently.
            // Only enough rows to keep the cursor on screen; the rest are blank.
            let excess = rows - newRows
            let fromTop = min(excess, max(0, cursor.row - (newRows - 1)))
            for row in 0..<fromTop { scrollback.push(lines[row]) }
            if fromTop > 0 {
                lines.removeFirst(fromTop)
                cursor.row -= fromTop
            }
            let surplus = excess - fromTop
            if surplus > 0 { lines.removeLast(surplus) }
        } else if newRows > rows {
            lines.append(contentsOf: repeatElement(Line(), count: newRows - rows))
        }
        rows = newRows
        resizeTabStops(to: newColumns)
        columns = newColumns
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        pendingWrap = false
        marginTop = min(marginTop, rows - 1)
        marginBottom = min(marginBottom, rows - 1)
        if marginTop >= marginBottom {
            // The region no longer fits; fall back to the whole screen.
            marginTop = 0
            marginBottom = rows - 1
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
        moveCursor(row: 0, column: 0)
    }

    // MARK: - Scrolling

    /// Rows reach scrollback only when the region is the whole screen — a
    /// partial region is an application's (tmux, vim), not history. `wrapped`
    /// travels with them (D03).
    public mutating func scrollUp(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        let saveToHistory = marginTop == 0 && marginBottom == rows - 1
        if saveToHistory {
            for row in 0..<count { scrollback.push(lines[row]) }
            lines.rotateUp(count)
            return
        }
        for row in marginTop..<(marginBottom - count + 1) {
            lines[row] = lines[row + count]
        }
        for row in (marginBottom - count + 1)...marginBottom {
            lines[row] = Line()
        }
    }

    /// SD: nothing enters scrollback — scrolling down creates no history.
    public mutating func scrollDown(_ count: Int) {
        let count = min(max(0, count), marginBottom - marginTop + 1)
        guard count > 0 else { return }
        var row = marginBottom
        while row >= marginTop + count {
            lines[row] = lines[row - count]
            row -= 1
        }
        while row >= marginTop {
            lines[row] = Line()
            row -= 1
        }
    }

    // MARK: - Editing

    /// IL within the region; ignored outside it.
    public mutating func insertLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        var row = marginBottom
        while row >= cursor.row + count {
            lines[row] = lines[row - count]
            row -= 1
        }
        while row >= cursor.row {
            lines[row] = erasedLine()
            row -= 1
        }
        pendingWrap = false
    }

    /// DL within the region; deleted rows are never history.
    public mutating func deleteLines(_ count: Int) {
        guard cursor.row >= marginTop, cursor.row <= marginBottom else { return }
        let count = min(max(0, count), marginBottom - cursor.row + 1)
        guard count > 0 else { return }
        var row = cursor.row
        while row + count <= marginBottom {
            lines[row] = lines[row + count]
            row += 1
        }
        while row <= marginBottom {
            lines[row] = erasedLine()
            row += 1
        }
        pendingWrap = false
    }

    public mutating func insertCharacters(_ count: Int) {
        lines[cursor.row].insertCells(count, at: cursor.column, template: pen.eraseCell, width: columns)
        repairWidePairs(row: cursor.row, template: pen.eraseCell)
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

    // MARK: - Save and restore

    /// DECSC: cursor, pen, pending wrap. No DECOM or character sets.
    public mutating func saveCursor() {
        savedCursor = cursor
        savedPen = pen
        savedPendingWrap = pendingWrap
    }

    /// DECRC; with nothing saved, home and the default rendition.
    public mutating func restoreCursor() {
        guard let savedCursor, let savedPen else {
            moveCursor(row: 0, column: 0)
            pen.reset()
            return
        }
        moveCursor(row: savedCursor.row, column: savedCursor.column)
        pen = savedPen
        pendingWrap = savedPendingWrap
    }

    // MARK: - Alternate screen

    /// `?1049` set: the main screen is parked whole in `suspendedMain`; the
    /// alternate screen is blank with no scrollback.
    public mutating func enterAlternateScreen() {
        saveCursor()
        guard suspendedMain == nil else {
            eraseDisplay(.all)
            marginTop = 0
            marginBottom = rows - 1
            moveCursor(row: 0, column: 0)
            return
        }
        suspendedMain = SuspendedScreen(self)
        lines = ScreenLines(repeating: Line(), count: rows)
        scrollback = Scrollback(limit: 0)
        graphemes = GraphemeTable()
        imagePlacements = ImagePlacementTable()
        marginTop = 0
        marginBottom = rows - 1
        isAlternateScreenActive = true
        moveCursor(row: 0, column: 0)
    }

    /// `?1049` reset. A resize meanwhile applies to the parked screen too.
    public mutating func exitAlternateScreen() {
        guard let suspended = suspendedMain else { return }
        suspendedMain = nil
        var main = suspended.grid
        main.cursorStyle = cursorStyle  // the style is global, not per screen
        main.cellPixelHeight = cellPixelHeight  // a property of the window
        main.cellPixelWidth = cellPixelWidth
        // Terminal-wide, not per screen: `self = main` would restore the old
        // value.
        main.reverseWraparoundEnabled = reverseWraparoundEnabled
        if main.rows != rows || main.columns != columns {
            main.resize(rows: rows, columns: columns)
        }
        self = main
        restoreCursor()
    }
}

/// The parked main screen, behind a reference (a value type cannot hold
/// itself). Written once, read once, never mutated — so snapshots sharing it
/// make `Sendable` honest.
private final class SuspendedScreen: @unchecked Sendable {
    let grid: Grid

    init(_ grid: Grid) {
        self.grid = grid
    }
}
