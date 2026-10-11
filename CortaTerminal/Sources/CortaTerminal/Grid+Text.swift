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

/// Logical lines — rows joined by `wrapped` (D03) — so search and link
/// detection find a match across a soft wrap without knowing how rows are
/// stored. Row numbering matches `Selection.swift` (negative is scrollback).
public struct LogicalLine: Sendable {
    public let firstRow: Int

    public let lastRow: Int

    public let text: String

    /// The cell each character came from; use `position(at:)`.
    private let positions: [(row: Int, column: Int)]

    fileprivate init(firstRow: Int, lastRow: Int, text: String, positions: [(row: Int, column: Int)]) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.text = text
        self.positions = positions
    }

    public func position(at offset: Int) -> (row: Int, column: Int)? {
        guard offset >= 0, offset < positions.count else { return nil }
        return positions[offset]
    }
}

extension Grid {
    public var documentRowRange: Range<Int> {
        (-scrollback.count)..<rows
    }

    /// Out-of-range rows read as empty.
    public func documentLine(_ row: Int) -> Line {
        if row < 0 {
            let index = scrollback.count + row
            guard index >= 0, index < scrollback.count else { return Line() }
            return scrollback[index]
        }
        guard row >= 0, row < rows else { return Line() }
        return line(row)
    }

    /// Lazy: the scrollback is never materialized.
    public func logicalLines() -> LogicalLineSequence {
        LogicalLineSequence(grid: self)
    }

    /// Newest first, so a capped search keeps the recent matches.
    public func reversedLogicalLines() -> ReversedLogicalLineSequence {
        ReversedLogicalLineSequence(grid: self)
    }

    /// Spans only: a caller that can answer from the cells (`Search.find`'s
    /// ASCII path) pays for a `LogicalLine` only where it must.
    func reversedLogicalLineSpans() -> ReversedLogicalLineSpanSequence {
        ReversedLogicalLineSpanSequence(grid: self)
    }

    /// The chain as ASCII bytes plus each byte's position, into the caller's
    /// buffers (replaced, not appended) so a sweep allocates once. `false` at the
    /// first cell ASCII cannot hold; the caller then falls back. Trims like
    /// `joinedLogicalLine`. The span must already be one wrap chain — unchecked.
    func fillWithASCIILogicalLine(
        firstRow: Int, lastRow: Int,
        text: inout ContiguousArray<UInt8>,
        rows: inout ContiguousArray<Int32>,
        columns: inout ContiguousArray<Int32>,
        historyReader: inout Scrollback.ASCIIReader,
        nonASCIIIsOpaque: (UInt32) -> Bool = { _ in false }
    ) -> Bool {
        text.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        columns.removeAll(keepingCapacity: true)
        var row = firstRow
        while row <= lastRow {
            let rowStart = text.count
            if row < 0 {
                guard scrollback.appendASCIIRow(at: scrollback.count + row, documentRow: row,
                    text: &text, rows: &rows, columns: &columns, reader: &historyReader, nonASCIIIsOpaque: nonASCIIIsOpaque) else { return false }
                if row == lastRow || !scrollback.isWrapped(at: scrollback.count + row) {
                    while text.count > rowStart, text.last == 0x20 {
                        text.removeLast(); rows.removeLast(); columns.removeLast()
                    }
                }
                row += 1
                continue
            }
            let currentLine = documentLine(row)
            var column = 0
            while column < currentLine.count {
                let cell = currentLine[column]
                defer { column += 1 }
                // Parity with `joinedLogicalLine`: reflow can leave a lone spacer.
                if cell.attributes.contains(.wideSpacer) { continue }
                // A field test, not a lookup — the per-cell cost must stay here.
                guard cell.grapheme.isNone else { return false }
                if cell.scalar < 0x80 {
                    text.append(UInt8(truncatingIfNeeded: cell.scalar))
                } else {
                    guard nonASCIIIsOpaque(cell.scalar) else { return false }
                    // A nonmatching separator preserves positions and prevents
                    // an ASCII query from spanning an intervening Unicode cell.
                    text.append(0x80)
                }
                rows.append(Int32(row))
                columns.append(Int32(column))
            }
            let continuesToNext = row != lastRow && currentLine.wrapped
            if !continuesToNext {
                while text.count > rowStart, text.last == 0x20 {
                    text.removeLast()
                    rows.removeLast()
                    columns.removeLast()
                }
            }
            row += 1
        }
        return true
    }

    public func logicalLine(containing row: Int) -> LogicalLine {
        let span = logicalLineRowSpan(containing: row)
        return joinedLogicalLine(firstRow: span.first, lastRow: span.last)
    }

    /// For a caller that already has the span. Internal: it carries the
    /// unchecked one-chain precondition; `logicalLine(containing:)` is public.
    func logicalLine(firstRow: Int, lastRow: Int) -> LogicalLine {
        joinedLogicalLine(firstRow: firstRow, lastRow: lastRow)
    }

    /// Lets a per-mouse-move caller skip the join for chains over budget.
    /// Reads only each row's wrap flag: a 2 MB single-line file is one chain
    /// through the whole scrollback, and copying every row out on each mouse
    /// move made hovering it stutter.
    func logicalLineRowSpan(containing row: Int) -> (first: Int, last: Int) {
        var top = row
        while isDocumentLineWrapped(top - 1) { top -= 1 }
        var bottom = row
        while isDocumentLineWrapped(bottom), bottom < rows - 1 { bottom += 1 }
        return (top, bottom)
    }

    /// `documentLine(row).wrapped`, without the copy.
    func isDocumentLineWrapped(_ row: Int) -> Bool {
        if row < 0 { return scrollback.isWrapped(at: scrollback.count + row) }
        guard row < rows else { return false }
        return lines[row].wrapped
    }

    /// Not re-joined: accessibility reads by screen line, as a person reading
    /// the screen aloud does.
    public func rowText(_ row: Int) -> String {
        joinedLogicalLine(firstRow: row, lastRow: row).text
    }

    /// Wide characters, combining sequences and trimmed blanks mean columns
    /// and character offsets do not line up by themselves.
    public func rowTextWithColumns(_ row: Int) -> (text: String, columns: [Int]) {
        let line = joinedLogicalLine(firstRow: row, lastRow: row)
        var columns: [Int] = []
        columns.reserveCapacity(line.text.count)
        for offset in 0..<line.text.count {
            columns.append(line.position(at: offset)?.column ?? offset)
        }
        return (line.text, columns)
    }

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

/// Holds one chain's rows at a time.
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

public struct ReversedLogicalLineSequence: Sequence {
    private let grid: Grid

    fileprivate init(grid: Grid) {
        self.grid = grid
    }

    public func makeIterator() -> Iterator {
        Iterator(grid: grid)
    }

    public struct Iterator: IteratorProtocol {
        private let grid: Grid
        /// Built on the span walk, so a fix to chain-finding cannot miss one.
        private var spans: ReversedLogicalLineSpanSequence.Iterator

        fileprivate init(grid: Grid) {
            self.grid = grid
            self.spans = grid.reversedLogicalLineSpans().makeIterator()
        }

        public mutating func next() -> LogicalLine? {
            guard let span = spans.next() else { return nil }
            return grid.joinedLogicalLine(firstRow: span.firstRow, lastRow: span.lastRow)
        }
    }
}


struct LogicalLineSpan: Sendable, Equatable {
    let firstRow: Int
    let lastRow: Int
}

struct ReversedLogicalLineSpanSequence: Sequence {
    private let grid: Grid

    fileprivate init(grid: Grid) {
        self.grid = grid
    }

    func makeIterator() -> Iterator {
        Iterator(grid: grid)
    }

    struct Iterator: IteratorProtocol {
        private let grid: Grid
        private var nextRow: Int
        private let lowerBound: Int

        fileprivate init(grid: Grid) {
            self.grid = grid
            self.nextRow = grid.rows - 1
            self.lowerBound = grid.documentRowRange.lowerBound
        }

        mutating func next() -> LogicalLineSpan? {
            guard nextRow >= lowerBound else { return nil }
            let last = nextRow
            var first = last
            while grid.isDocumentLineWrapped(first - 1) { first -= 1 }
            nextRow = first - 1
            return LogicalLineSpan(firstRow: first, lastRow: last)
        }
    }
}
