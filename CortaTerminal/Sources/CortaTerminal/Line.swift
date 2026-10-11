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

/// What a row means to the shell (OSC 133). It rides on the `Line`, like
/// `wrapped`, because rows scroll and reflow and anything keyed by position
/// drifts; it fits existing padding, so it costs nothing.
public enum LineMark: UInt8, Sendable {
    case none = 0
    /// A prompt whose command has not finished.
    case prompt = 1
    case promptSucceeded = 2
    case promptFailed = 3
    /// Where output begins (`C`): otherwise "the last command's output" must be
    /// guessed as one row past the prompt, wrong for a two-line prompt.
    case outputStart = 4
    /// SIGINT-style exit status, retained even when command history is disabled.
    case promptInterrupted = 5

    /// Not `!= .none`: jumping to an output-start mark lands a line low.
    public var isPrompt: Bool {
        switch self {
        case .prompt, .promptSucceeded, .promptFailed, .promptInterrupted: return true
        case .none, .outputStart: return false
        }
    }

    /// A prompt whose command reported how it ended: the rows that carry a
    /// status rule.
    public var hasOutcome: Bool {
        switch self {
        case .promptSucceeded, .promptFailed, .promptInterrupted: return true
        case .none, .prompt, .outputStart: return false
        }
    }
}

/// One row of the grid. Variable length — cells only up to the last written
/// column; reading past the end yields `Cell.blank` (D05) — and carrying
/// `wrapped` (D03).
public struct Line: Equatable, Sendable {
    /// No trailing blanks after `trimTrailingBlanks()`; may have them while
    /// editing.
    public private(set) var cells: ContiguousArray<Cell>

    /// Continued because text reached the margin, not because of a newline.
    public var wrapped: Bool

    public var mark: LineMark = .none

    public init(wrapped: Bool = false) {
        self.cells = []
        self.wrapped = wrapped
    }

    /// A copy out of `Scrollback`'s shared arena — the read-side cost of the
    /// arena needing no growth headroom.
    init(wrapped: Bool, mark: LineMark = .none, cells: ArraySlice<Cell>) {
        self.cells = ContiguousArray(cells)
        self.wrapped = wrapped
        self.mark = mark
    }

    mutating func reserveCapacity(_ capacity: Int) { cells.reserveCapacity(capacity) }

    public var count: Int { cells.count }

    public var isEmpty: Bool { cells.isEmpty }

    /// Reads past the end are blank; writes past it pad with blanks.
    public subscript(column: Int) -> Cell {
        @inline(__always)
        get {
            guard column >= 0, column < cells.count else { return .blank }
            return cells[column]
        }
        @inline(__always)
        set {
            guard column >= 0 else { return }
            grow(to: column + 1)
            cells[column] = newValue
        }
    }

    /// Reflow already validated a contiguous narrow run and reserved its row.
    mutating func appendNarrowCells(_ contents: ArraySlice<Cell>) {
        cells.append(contentsOf: contents)
    }

    /// Install a wide pair with one growth and one mutable-buffer borrow.
    mutating func overwriteWide(_ lead: Cell, spacer: Cell, at column: Int) {
        grow(to: column + 2)
        cells.withUnsafeMutableBufferPointer { buffer in
            buffer[column] = lead
            buffer[column + 1] = spacer
        }
    }

    /// One in-row ASCII run: only the two ends can split a wide pair. Writes
    /// through the buffer pointer — `grow(to:)` already fixed the length, so
    /// per-element bounds checks are redundant.
    mutating func overwriteASCII(_ bytes: ArraySlice<UInt8>, at column: Int, pen: Pen) {
        guard !bytes.isEmpty, column >= 0 else { return }
        let end = column + bytes.count
        if column < cells.count, cells[column].attributes.contains(.wideSpacer), column > 0 {
            cells[column - 1] = pen.eraseCell
        }
        if end - 1 < cells.count, cells[end - 1].attributes.contains(.wide), end < cells.count {
            cells[end] = pen.eraseCell
        }
        grow(to: end)
        let template = pen.cell(0x20)
        cells.withUnsafeMutableBufferPointer { buffer in
            var destination = column
            var cell = template
            for byte in bytes {
                cell.scalar = UInt32(byte)
                buffer[destination] = cell
                destination += 1
            }
        }
    }

    public mutating func fill(_ cell: Cell, in range: Range<Int>) {
        let lower = max(0, range.lowerBound)
        guard range.upperBound > lower else { return }
        grow(to: range.upperBound)
        for column in lower..<range.upperBound {
            cells[column] = cell
        }
    }

    /// A blank erase to the end drops the cells (a mostly empty screen stays
    /// cheap); one under a background colour is visible, so it is stored.
    public mutating func erase(_ range: Range<Int>, with template: Cell) {
        let lower = max(0, range.lowerBound)
        guard range.upperBound > lower else { return }
        if template.isBlank, range.upperBound >= cells.count {
            if lower < cells.count { cells.removeSubrange(lower...) }
            return
        }
        fill(template, in: lower..<range.upperBound)
    }

    /// A narrower screen that does not reflow (the alternate screen): cells
    /// past the new width go, and so does a pair the margin now cuts, whose
    /// lead would otherwise stand alone in the last column.
    mutating func truncate(toWidth width: Int) {
        guard cells.count > width else { return }
        cells.removeSubrange(max(0, width)...)
        if let last = cells.indices.last, cells[last].attributes.contains(.wide) {
            cells[last] = .blank
        }
        trimTrailingBlanks()
    }

    /// Keeps the allocation; a cleared row continues nothing.
    public mutating func clear() {
        cells.removeAll(keepingCapacity: true)
        wrapped = false
    }

    /// Empty a vacated screen slot without releasing its cell allocation.
    mutating func recycle() {
        clear()
        mark = .none
    }

    /// The arena copies this prefix without triggering copy-on-write.
    var trimmedCount: Int {
        var end = cells.count
        while end > 0, cells[end - 1].isBlank { end -= 1 }
        return end
    }

    /// Before a row enters scrollback, where it is never edited again.
    public mutating func trimTrailingBlanks() {
        let end = trimmedCount
        if end < cells.count { cells.removeSubrange(end...) }
    }

    /// ICH; cells past `width` are lost, and editing breaks the wrap.
    public mutating func insertCells(_ count: Int, at column: Int, template: Cell, width: Int) {
        guard column >= 0, column < width else { return }
        let count = min(max(0, count), width - column)
        guard count > 0 else { return }
        grow(to: width)
        var col = width - 1
        while col >= column + count {
            cells[col] = cells[col - count]
            col -= 1
        }
        while col >= column {
            cells[col] = template
            col -= 1
        }
        wrapped = false
        if template.isBlank { trimTrailingBlanks() }
    }

    public mutating func deleteCells(_ count: Int, at column: Int, template: Cell, width: Int) {
        guard column >= 0, column < width else { return }
        let count = min(max(0, count), width - column)
        guard count > 0 else { return }
        grow(to: width)
        for col in column..<(width - count) {
            cells[col] = cells[col + count]
        }
        for col in (width - count)..<width {
            cells[col] = template
        }
        wrapped = false
        if template.isBlank { trimTrailingBlanks() }
    }

    @inline(__always)
    private mutating func grow(to length: Int) {
        let missing = length - cells.count
        guard missing > 0 else { return }
        cells.append(contentsOf: repeatElement(Cell.blank, count: missing))
    }
}
