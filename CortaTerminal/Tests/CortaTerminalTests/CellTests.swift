import Testing

@testable import CortaTerminal

/// M1.3 — the cell and row layout the whole grid is built on.
@Suite("Cell and Line")
struct CellTests {
    /// The size of a cell multiplies by every stored cell in the scrollback,
    /// so a regression here is a memory regression measured in hundreds of
    /// megabytes (`DESIGN.md` §2.3, `PERFORMANCE.md` §4). If this assertion
    /// fails, the fix is to shrink the field that grew, not to raise the
    /// number.
    @Test("a cell is 16 bytes")
    func cellLayoutIsFixed() {
        #expect(MemoryLayout<Cell>.size == 16)
        #expect(MemoryLayout<Cell>.stride == 16)
        #expect(MemoryLayout<Cell>.alignment == 4)
    }

    @Test("a blank cell is a space in the default colours")
    func blankCellIsASpace() {
        #expect(Cell.blank.scalar == 0x20)
        #expect(Cell.blank.foreground == .default)
        #expect(Cell.blank.background == .default)
        #expect(Cell.blank.attributes.isEmpty)
        #expect(Cell.blank.grapheme == .none)
        #expect(Cell.blank.isBlank)
    }

    /// A space under a non-default background is visible, and must therefore
    /// survive trimming.
    @Test("a space with a background colour is not blank")
    func colouredSpaceIsNotBlank() {
        var cell = Cell.blank
        cell.background = .indexed(4)
        #expect(!cell.isBlank)
    }

    @Test("colours round-trip through their packed form")
    func coloursRoundTrip() {
        #expect(Color.default.isDefault)
        #expect(Color.default.index == nil)
        #expect(Color.indexed(200).index == 200)
        #expect(!Color.indexed(0).isDefault)
        #expect(Color.indexed(0) != Color.default)

        let rgb = Color.rgb(0x12, 0x34, 0x56)
        #expect(rgb.components?.red == 0x12)
        #expect(rgb.components?.green == 0x34)
        #expect(rgb.components?.blue == 0x56)
        #expect(rgb.index == nil)
    }

    @Test("attributes are independent bits")
    func attributesAreIndependent() {
        var attributes: CellAttributes = [.bold, .underline]
        #expect(attributes.contains(.bold))
        #expect(!attributes.contains(.italic))
        attributes.remove(.bold)
        #expect(attributes == .underline)
    }
}

@Suite("Line")
struct LineTests {
    @Test("a new line stores nothing and wraps nothing")
    func newLineIsEmpty() {
        let line = Line()
        #expect(line.count == 0)
        #expect(line.isEmpty)
        #expect(!line.wrapped)
        #expect(line[0] == .blank)
        #expect(line[10_000] == .blank)
        #expect(line[-1] == .blank)
    }

    /// Rows are variable length: writing column 4 stores five cells, not the
    /// screen width.
    @Test("writing a column pads the gap and stores no more")
    func writingPadsTheGap() {
        var line = Line()
        line[4] = Cell(scalar: 0x41)
        #expect(line.count == 5)
        #expect(line[0] == .blank)
        #expect(line[3] == .blank)
        #expect(line[4].scalar == 0x41)
        #expect(line[5] == .blank)
    }

    @Test("erasing to the end of a row drops the cells")
    func erasingToTheEndTruncates() {
        var line = Line()
        for column in 0..<8 { line[column] = Cell(scalar: 0x41) }
        line.erase(4..<8, with: .blank)
        #expect(line.count == 4)
        #expect(line[4] == .blank)
    }

    /// The background colour is visible, so a coloured erase must be stored
    /// even though the characters are spaces.
    @Test("erasing under a background colour keeps the cells")
    func colouredEraseIsStored() {
        var line = Line()
        for column in 0..<8 { line[column] = Cell(scalar: 0x41) }
        var template = Cell.blank
        template.background = .indexed(2)
        line.erase(4..<8, with: template)
        #expect(line.count == 8)
        #expect(line[7] == template)
    }

    @Test("erasing the middle of a row keeps the tail")
    func erasingTheMiddleKeepsTheTail() {
        var line = Line()
        for column in 0..<8 { line[column] = Cell(scalar: 0x41) }
        line.erase(2..<4, with: .blank)
        #expect(line.count == 8)
        #expect(line[2] == .blank)
        #expect(line[4].scalar == 0x41)
    }

    @Test("trimming drops trailing blanks only")
    func trimmingDropsTrailingBlanks() {
        var line = Line()
        line[0] = Cell(scalar: 0x41)
        line[6] = Cell(scalar: 0x42)
        line[7] = .blank
        line.trimTrailingBlanks()
        #expect(line.count == 7)
        #expect(line[6].scalar == 0x42)
        #expect(line[1] == .blank)
    }

    @Test("clearing a row clears its wrap flag")
    func clearingClearsTheWrapFlag() {
        var line = Line()
        line[0] = Cell(scalar: 0x41)
        line.wrapped = true
        line.clear()
        #expect(line.count == 0)
        #expect(!line.wrapped)
    }
}

@Suite("Grapheme side table")
struct GraphemeTableTests {
    @Test("identical clusters intern to one id")
    func clustersAreInterned() {
        var table = GraphemeTable()
        // "e" + U+0301 COMBINING ACUTE ACCENT.
        let first = table.intern([0x65, 0x0301])
        let second = table.intern([0x65, 0x0301])
        #expect(first == second)
        #expect(table.count == 1)
        #expect(table.scalars(for: first ?? .none) == [0x65, 0x0301])
    }

    @Test("distinct clusters get distinct non-zero ids")
    func distinctClustersGetDistinctIDs() {
        var table = GraphemeTable()
        let a = table.intern([0x65, 0x0301])
        let b = table.intern([0x1F468, 0x200D, 0x1F469])
        #expect(a != b)
        #expect(a?.isNone == false)
        #expect(b?.isNone == false)
        #expect(table.count == 2)
    }

    @Test("the empty id resolves to nothing")
    func theEmptyIDResolvesToNothing() {
        let table = GraphemeTable()
        #expect(table.scalars(for: .none) == nil)
    }
}
