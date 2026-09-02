import Testing

@testable import CortaTerminal

/// M3.7 — the selection model: wrap joining on copy, trailing-blank
/// trimming, word and logical-line expansion, and anchoring to the document
/// while output scrolls the viewport.
private func point(_ row: Int, _ column: Int) -> SelectionPoint {
    SelectionPoint(row: row, column: column)
}

@Suite("Selection")
struct SelectionTests {
    // MARK: - Copy semantics

    @Test("a soft-wrapped line copies as one line with no inserted newline")
    func wrappedLineCopiesAsOneLine() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("abcdefghijklmnopqrstuvwxy".utf8))
        let grid = terminal.grid
        // The 25-character command occupies rows 0-2, the first two wrapped.
        #expect(grid.line(0).wrapped)
        #expect(grid.line(1).wrapped)
        #expect(!grid.line(2).wrapped)

        let range = SelectionRange(anchor: point(0, 0), head: point(2, 4))
        #expect(Selection.text(of: range, in: grid) == "abcdefghijklmnopqrstuvwxy")
    }

    @Test("trailing blanks are trimmed from each copied line")
    func trailingBlanksAreTrimmed() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("abc\r\nde\r\n".utf8))
        let grid = terminal.grid

        // Full-width selections: the unwritten cells past "abc"/"de" must
        // not become trailing spaces on the clipboard.
        let range = SelectionRange(anchor: point(0, 0), head: point(1, 9))
        #expect(Selection.text(of: range, in: grid) == "abc\nde")
    }

    @Test("a hard newline between rows becomes one newline")
    func hardNewlinesSeparateLines() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("one\r\ntwo\r\nthree".utf8))
        let range = SelectionRange(anchor: point(0, 0), head: point(2, 4))
        #expect(Selection.text(of: range, in: terminal.grid) == "one\ntwo\nthree")
    }

    @Test("a wide character's spacer cell contributes no stray space")
    func wideSpacerCopiesNothing() {
        var terminal = Terminal(rows: 5, columns: 10)
        terminal.feed(Array("中文x".utf8))
        let grid = terminal.grid
        #expect(grid.line(0)[1].attributes.contains(.wideSpacer))
        #expect(grid.line(0)[3].attributes.contains(.wideSpacer))

        let range = SelectionRange(anchor: point(0, 0), head: point(0, 4))
        #expect(Selection.text(of: range, in: grid) == "中文x")
    }

    @Test("a grapheme cluster copies whole, not just its base scalar")
    func graphemeClusterCopiesWhole() {
        var terminal = Terminal(rows: 5, columns: 10)
        // "e" + combining acute (U+0301): one cell, two scalars.
        terminal.feed(Array("e\u{301}x".utf8))
        let grid = terminal.grid
        #expect(!grid.line(0)[0].grapheme.isNone)

        let range = SelectionRange(anchor: point(0, 0), head: point(0, 1))
        #expect(Selection.text(of: range, in: grid) == "e\u{301}x")
    }

    // MARK: - Word selection

    @Test("a path selects as one word")
    func pathSelectsAsOneWord() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("open /usr/local/bin/tool-x.y done".utf8))
        let grid = terminal.grid

        // A click anywhere inside the path...
        let range = Selection.range(at: point(0, 12), unit: .word, in: grid)
        #expect(Selection.text(of: range, in: grid) == "/usr/local/bin/tool-x.y")
        #expect(range.start == point(0, 5))
        #expect(range.end == point(0, 27))
    }

    @Test("word characters are letters, digits, and _ - . /")
    func wordCharacterClassification() {
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "a"))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "Z"))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "7"))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "_"))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "-"))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "."))))
        #expect(Selection.isWordScalar(UInt32(UInt8(ascii: "/"))))
        #expect(!Selection.isWordScalar(UInt32(UInt8(ascii: " "))))
        #expect(!Selection.isWordScalar(UInt32(UInt8(ascii: ":"))))
        #expect(!Selection.isWordScalar(UInt32(UInt8(ascii: "("))))
        #expect(!Selection.isWordScalar(UInt32(UInt8(ascii: "="))))
        // Non-ASCII letters are letters.
        #expect(Selection.isWordScalar(0x4E2D))  // 中
    }

    @Test("a click on a non-word character selects only that cell")
    func clickOnNonWordSelectsOneCell() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("foo (bar)".utf8))
        let grid = terminal.grid

        let range = Selection.range(at: point(0, 4), unit: .word, in: grid)
        #expect(range.start == point(0, 4))
        #expect(range.end == point(0, 4))
    }

    @Test("a word split across a soft wrap selects whole")
    func wordSpanningAWrapSelectsWhole() {
        var terminal = Terminal(rows: 5, columns: 10)
        // "x longfile" fills row 0; "path" starts row 1 — one wrapped word.
        terminal.feed(Array("x longfilepath y".utf8))
        let grid = terminal.grid
        #expect(grid.line(0).wrapped)

        let range = Selection.range(at: point(1, 2), unit: .word, in: grid)
        #expect(Selection.text(of: range, in: grid) == "longfilepath")
        #expect(range.start == point(0, 2))
        #expect(range.end == point(1, 3))
    }

    // MARK: - Logical-line selection

    @Test("triple-click selects the logical line across wraps")
    func tripleClickSelectsLogicalLine() {
        var terminal = Terminal(rows: 6, columns: 10)
        terminal.feed(Array("ls\r\nabcdefghijklmnopqrstuvwxy\r\nnext".utf8))
        let grid = terminal.grid

        // A click on any of rows 1-3 (the wrapped command) selects all of it.
        for row in 1...3 {
            let range = Selection.range(at: point(row, 3), unit: .logicalLine, in: grid)
            #expect(range.start == point(1, 0))
            #expect(range.end == point(3, 9))
        }
        let range = Selection.range(at: point(2, 3), unit: .logicalLine, in: grid)
        #expect(Selection.text(of: range, in: grid) == "abcdefghijklmnopqrstuvwxy")

        // The rows before and after are logical lines of their own.
        let before = Selection.range(at: point(0, 1), unit: .logicalLine, in: grid)
        #expect(before.start == point(0, 0))
        #expect(before.end == point(0, 9))
        let after = Selection.range(at: point(4, 1), unit: .logicalLine, in: grid)
        #expect(after.start == point(4, 0))
        #expect(after.end == point(4, 9))
    }

    @Test("a word drag extends word by word from the anchor")
    func wordDragExtendsByWords() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("alpha beta gamma".utf8))
        let grid = terminal.grid

        // Anchor inside "alpha", drag into "gamma": whole words both ends.
        let range = Selection.range(from: point(0, 2), to: point(0, 12), unit: .word, in: grid)
        #expect(range.start == point(0, 0))
        #expect(range.end == point(0, 15))
        #expect(Selection.text(of: range, in: grid) == "alpha beta gamma")
    }

    // MARK: - Anchoring

    @Test("a selection survives output scrolling the viewport")
    func selectionSurvivesScrolling() {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("target\r\n".utf8))
        let before = terminal.grid

        let range = SelectionRange(anchor: point(0, 0), head: point(0, 5))
        #expect(Selection.text(of: range, in: before) == "target")

        // Ten more lines push "target" off the screen into the scrollback.
        for i in 0..<10 {
            terminal.feed(Array("filler\(i)\r\n".utf8))
        }
        let after = terminal.grid
        let growth = after.scrollback.count - before.scrollback.count
        #expect(growth > 0)

        let shifted = range.shifted(byScrollbackGrowth: growth)
        #expect(shifted.start.row < 0, "the line now lives in the scrollback")
        #expect(Selection.text(of: shifted, in: after) == "target")
    }

    @Test("a selection over scrollback rows reads history")
    func selectionOverScrollbackRows() {
        var terminal = Terminal(rows: 3, columns: 10, scrollbackLimit: 100)
        for i in 0..<6 {
            terminal.feed(Array("line\(i)abc\r\n".utf8))
        }
        let grid = terminal.grid
        // "line0abc" is the oldest history line: with N lines pushed, it is
        // document row -(count), the row just above the screen is -1.
        let count = grid.scrollback.count
        #expect(count == 4)
        let range = SelectionRange(anchor: point(-count, 0), head: point(-count, 8))
        #expect(Selection.text(of: range, in: grid) == "line0abc")
    }

    @Test("a stale selection past retained history reads as blank, never traps")
    func outOfRangeRowsAreSafe() {
        var terminal = Terminal(rows: 3, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("hi\r\n".utf8))
        let grid = terminal.grid
        let range = SelectionRange(anchor: point(-500, 0), head: point(-499, 9))
        #expect(Selection.text(of: range, in: grid) == "\n")
    }

    @Test("ranges normalize drag direction")
    func rangesNormalize() {
        let range = SelectionRange(anchor: point(3, 5), head: point(1, 2))
        #expect(range.start == point(1, 2))
        #expect(range.end == point(3, 5))
    }
}
