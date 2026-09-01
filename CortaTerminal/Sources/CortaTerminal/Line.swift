/// One row of the grid.
///
/// Two properties matter and both are load-bearing:
///
/// **Variable length.** A row stores cells only up to its last written
/// column. A fixed 200-cell row over a 100k-line scrollback is ~320 MB, which
/// is not acceptable for the log-heavy workloads Corta targets
/// (`DESIGN.md` §2.3). Reading past the end yields `Cell.blank`.
///
/// **The `wrapped` flag.** A row that filled its last column and continued on
/// the next row records that here. Reflow, selection across a soft wrap, and
/// search across a wrap boundary all depend on it, and adding it later means
/// rewriting the grid (`DESIGN.md` §2.1).
public struct Line: Equatable, Sendable {
    /// Cells up to the last written column. Never contains trailing blanks
    /// after `trimTrailingBlanks()`; may during editing.
    public private(set) var cells: ContiguousArray<Cell>

    /// True when this row continues onto the next one because text reached
    /// the right margin — not because the program printed a newline.
    public var wrapped: Bool

    public init(wrapped: Bool = false) {
        self.cells = []
        self.wrapped = wrapped
    }

    /// The number of stored cells, which is one past the last written column.
    public var count: Int { cells.count }

    public var isEmpty: Bool { cells.isEmpty }

    /// Reads or writes a column. Reads past the stored end return
    /// `Cell.blank`; writes past it pad the gap with blanks.
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

    /// Sets every column in `range` to `cell`.
    public mutating func fill(_ cell: Cell, in range: Range<Int>) {
        let lower = max(0, range.lowerBound)
        guard range.upperBound > lower else { return }
        grow(to: range.upperBound)
        for column in lower..<range.upperBound {
            cells[column] = cell
        }
    }

    /// Erases `range` to `template`.
    ///
    /// When the template is blank and the range runs to the stored end, the
    /// cells are dropped rather than filled — that is what keeps a mostly
    /// empty screen cheap. A range erased under a non-default background is
    /// visible, so those cells are stored.
    public mutating func erase(_ range: Range<Int>, with template: Cell) {
        let lower = max(0, range.lowerBound)
        guard range.upperBound > lower else { return }
        if template.isBlank, range.upperBound >= cells.count {
            if lower < cells.count { cells.removeSubrange(lower...) }
            return
        }
        fill(template, in: lower..<range.upperBound)
    }

    /// Drops every cell, keeping the allocation for reuse, and clears the
    /// wrap flag — a cleared row continues nothing.
    public mutating func clear() {
        cells.removeAll(keepingCapacity: true)
        wrapped = false
    }

    /// Drops trailing blanks. Called before a row enters the scrollback,
    /// where it will be held for a long time and never edited again.
    public mutating func trimTrailingBlanks() {
        var end = cells.count
        while end > 0, cells[end - 1].isBlank { end -= 1 }
        if end < cells.count { cells.removeSubrange(end...) }
    }

    /// ICH — ECMA-48 §8.3.64: inserts `count` copies of `template` at
    /// `column`, shifting the rest right; cells pushed past `width` are
    /// lost. Editing a row breaks any continuation onto the next one, so
    /// the wrap flag is cleared.
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

    /// DCH — ECMA-48 §8.3.26: deletes `count` cells at `column`, shifting
    /// the rest left; the tail is filled with `template`.
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
        while cells.count < length {
            cells.append(.blank)
        }
    }
}
