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
    var tabStops: ContiguousArray<Bool>

    /// DECSCUSR state (xterm ctlseqs). Global to the terminal rather than
    /// per screen: it survives an alternate-screen round trip.
    public var cursorStyle: CursorStyle = .blinkingBlock
    /// A program's DECSCUSR override; parameter 0 and resets return to the
    /// application's configured default without changing that configuration.
    public var cursorStyleIsExplicit: Bool = false

    /// Grapheme clusters too large for a cell's single scalar
    /// (`DECISIONS.md` D05): combining-mark clusters and emoji ZWJ sequences.
    public var graphemes: GraphemeTable

    /// OSC 8 targets. Never cleared while an id may be on screen or in
    /// scrollback; unreferenced entries are swept under pressure
    /// (`internHyperlink`).
    public var hyperlinks: HyperlinkTable

    /// Failed interns left before the next futile sweep may run
    /// (`internHyperlink`, `combine`).
    var hyperlinkSweepDeferral = 0
    var graphemeSweepDeferral = 0
    /// Full-grid scans run by the two sweeps, for tests.
    var sideTableSweeps = 0
    /// Reflows since the owner last drained them (`Terminal.applyRowRemaps`):
    /// a column change, or leaving the alternate screen after one, renumbers
    /// rows that command records point at.
    var rowRemaps: [RowRemap] = []

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

    /// DECTCEM (`?25`). Terminal-wide, like the cursor style: a program hides
    /// the cursor while it draws and shows it again on the way out, and a
    /// screen switch in between must not undo either.
    public var isCursorVisible: Bool = true

    /// DECAWM (`?7`). Off, a character written in the last column stays
    /// there and the next one overwrites it: nothing wraps.
    public var autowrapEnabled: Bool = true

    /// DECOM (`?6`): cursor addressing (CUP, HVP, VPA) and the position
    /// report count from the scroll region's top, and the cursor cannot
    /// leave the region.
    public internal(set) var originMode: Bool = false

    /// Deferred wrap: printing into the last column arms this; the next
    /// character wraps first. Otherwise filling the last column and moving the
    /// cursor would scroll the screen.
    public internal(set) var pendingWrap: Bool

    /// DECSC's slot — cursor, pen and wrap state (VT510 §DECSC).
    var savedCursor: Cursor?
    var savedPen: Pen?
    var savedPendingWrap: Bool = false
    var savedOriginMode: Bool = false

    /// Image bytes on both screens, the parked main one included — what
    /// `KittyGraphics.maximumPaneImageBytes` bounds.
    public var retainedImageBytes: Int {
        imagePlacements.storedBytes + (suspendedMain?.grid.imagePlacements.storedBytes ?? 0)
    }

    /// True while the alternate screen is live.
    public internal(set) var isAlternateScreenActive: Bool = false

    var suspendedMain: SuspendedScreen?

    /// DECSTBM, zero-based and inclusive.
    public internal(set) var marginTop: Int = 0
    public internal(set) var marginBottom: Int

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
        self.savedOriginMode = false
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

    public var scrollEventsTotal: UInt64 { lines.scrollEventsTotal }
    /// Events kept for replay; a consumer further behind rebuilds.
    public static var scrollEventCapacity: Int { ScreenLines.scrollEventCapacity }
    public func scrollEvent(at sequence: UInt64) -> ScrollEvent? { lines.scrollEvent(at: sequence) }

    /// Test-only access without retaining a `Line` and sharing its buffer.
    func rowBufferAddress(_ row: Int) -> UInt? {
        lines[row].cells.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
    }

}

/// The parked main screen, behind a reference (a value type cannot hold
/// itself). Written once, read once, never mutated — so snapshots sharing it
/// make `Sendable` honest.
final class SuspendedScreen: Sendable {
    let grid: Grid

    init(_ grid: Grid) {
        self.grid = grid
    }
}
