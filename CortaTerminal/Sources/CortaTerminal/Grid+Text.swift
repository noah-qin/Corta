/// Read-only logical-line access over a grid (M4 Step 2).
///
/// Search (M4.4) and URL detection (M4.6) both need to read text out of the
/// grid without knowing how rows are stored, and the M4.2 storage rewrite
/// changes exactly that underneath them — this file is the boundary between
/// the two, so the rewrite has a safety net of its own tests to keep green.
///
/// A logical line is a maximal run of consecutive document rows joined by
/// the `wrapped` flag (`DESIGN.md` §2.1): one call to `write` may have
/// spanned several screen rows, and this file re-joins them so a search
/// match or a URL is found even when a soft wrap falls in the middle of it.
///
/// Document row numbering matches `Selection.swift`: row ≥ 0 is a live
/// screen row, row < 0 addresses the scrollback counting backwards from the
/// screen boundary (row -1 is the newest history line).
public struct LogicalLine: Sendable {
    /// The document row of the first (topmost / oldest) row in the chain.
    public let firstRow: Int

    /// The document row of the last (bottommost / newest) row in the chain.
    public let lastRow: Int

    /// The joined text, trailing blanks trimmed. No inserted newlines.
    public let text: String

    /// Parallel to `text`'s characters: `positions[i]` is the (row, column)
    /// of the grid cell that produced the i-th character. Use `position(at:)`
    /// rather than indexing this directly.
    private let positions: [(row: Int, column: Int)]

    fileprivate init(firstRow: Int, lastRow: Int, text: String, positions: [(row: Int, column: Int)]) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.text = text
        self.positions = positions
    }

    /// Maps a character offset in `text` back to the (row, column) it came
    /// from, so a match found in the joined text can be highlighted where it
    /// actually sits on the grid. `nil` for an out-of-range offset.
    public func position(at offset: Int) -> (row: Int, column: Int)? {
        guard offset >= 0, offset < positions.count else { return nil }
        return positions[offset]
    }
}

extension Grid {
    /// The full span of document rows: the oldest scrollback line through
    /// the last live screen row.
    public var documentRowRange: Range<Int> {
        (-scrollback.count)..<rows
    }

    /// The document row's line, in the numbering `Selection.swift` and
    /// `Grid.dump` use. Out-of-range rows read as an empty line.
    func documentLine(_ row: Int) -> Line {
        if row < 0 {
            let index = scrollback.count + row
            guard index >= 0, index < scrollback.count else { return Line() }
            return scrollback[index]
        }
        guard row >= 0, row < rows else { return Line() }
        return line(row)
    }

    /// Iterates logical lines across the whole document, oldest first,
    /// without materializing the scrollback into an array — each line is
    /// built from the underlying rows on demand.
    public func logicalLines() -> LogicalLineSequence {
        LogicalLineSequence(grid: self)
    }

    /// The logical line containing `row` — the chain of wrapped rows it
    /// belongs to, joined start to end.
    public func logicalLine(containing row: Int) -> LogicalLine {
        var top = row
        while documentLine(top - 1).wrapped { top -= 1 }
        var bottom = row
        while documentLine(bottom).wrapped, bottom < rows - 1 { bottom += 1 }
        return joinedLogicalLine(firstRow: top, lastRow: bottom)
    }

    /// Joins `firstRow...lastRow` (already known to be one wrap chain) into
    /// a `LogicalLine`, trimming trailing blanks and recording the
    /// per-character (row, column) mapping.
    fileprivate func joinedLogicalLine(firstRow: Int, lastRow: Int) -> LogicalLine {
        var text = ""
        var positions: [(row: Int, column: Int)] = []
        var row = firstRow
        while row <= lastRow {
            let currentLine = documentLine(row)
            var rowText = ""
            var rowPositions: [(row: Int, column: Int)] = []
            var column = 0
            while column < currentLine.count {
                let cell = currentLine[column]
                defer { column += 1 }
                if cell.attributes.contains(.wideSpacer) { continue }
                if let cluster = graphemes.scalars(for: cell.grapheme) {
                    let before = rowText.count
                    for scalar in cluster {
                        if let scalar = Unicode.Scalar(scalar) {
                            rowText.unicodeScalars.append(scalar)
                        }
                    }
                    for _ in before..<rowText.count { rowPositions.append((row, column)) }
                } else if let scalar = Unicode.Scalar(cell.scalar) {
                    rowText.unicodeScalars.append(scalar)
                    rowPositions.append((row, column))
                }
            }
            let continuesToNext = row != lastRow && currentLine.wrapped
            if !continuesToNext {
                while rowText.last == " " {
                    rowText.removeLast()
                    rowPositions.removeLast()
                }
            }
            text += rowText
            positions.append(contentsOf: rowPositions)
            row += 1
        }
        return LogicalLine(firstRow: firstRow, lastRow: lastRow, text: text, positions: positions)
    }
}

/// Lazily walks the document's logical lines, oldest first, one wrap chain
/// at a time — never holding more than one chain's rows in memory.
public struct LogicalLineSequence: Sequence {
    private let grid: Grid

    fileprivate init(grid: Grid) {
        self.grid = grid
    }

    public func makeIterator() -> Iterator {
        Iterator(grid: grid, nextRow: grid.documentRowRange.lowerBound)
    }

    public struct Iterator: IteratorProtocol {
        private let grid: Grid
        private var nextRow: Int
        private let end: Int

        fileprivate init(grid: Grid, nextRow: Int) {
            self.grid = grid
            self.nextRow = nextRow
            self.end = grid.rows
        }

        public mutating func next() -> LogicalLine? {
            guard nextRow < end else { return nil }
            let first = nextRow
            var last = first
            while grid.documentLine(last).wrapped, last < end - 1 { last += 1 }
            nextRow = last + 1
            return grid.joinedLogicalLine(firstRow: first, lastRow: last)
        }
    }
}
