import Testing

@testable import CortaTerminal

/// `?45` — DECBKM, reverse-wraparound mode (B06). While set, `BS`/`CUB`
/// running out of columns on a row that auto-wrapped from the one above
/// continue onto that row's last column instead of stopping at column 0.
@Suite("Reverse wraparound (?45)")
struct ReverseWraparoundTests {
    /// Fills exactly one row (auto-wrapping into the next) and leaves the
    /// cursor at the start of the second row — the shape every case below
    /// starts from.
    private func wrappedGrid(columns: Int = 10, rows: Int = 4) -> Grid {
        var grid = Grid(rows: rows, columns: columns)
        for scalar in String(repeating: "a", count: columns).unicodeScalars {
            grid.write(scalar.value)
        }
        // The write above leaves `pendingWrap` armed rather than having
        // moved onto row 1 yet — one more scalar is what actually commits
        // the wrap (`Grid.swift`'s own deferred-wrap comment).
        grid.write(Character("b").unicodeScalars.first!.value)
        return grid
    }

    @Test("off by default")
    func offByDefault() {
        let grid = Grid()
        #expect(!grid.reverseWraparoundEnabled)
    }

    @Test("disabled: BS and CUB stop at column 0 across a wrapped row, same as before")
    func disabledStopsAtColumnZero() {
        var grid = wrappedGrid()
        #expect(grid.cursor == Cursor(row: 1, column: 1))
        grid.moveCursor(row: 1, column: 0)
        grid.backspace()
        #expect(grid.cursor == Cursor(row: 1, column: 0))
        grid.moveCursorLeft(3)
        #expect(grid.cursor == Cursor(row: 1, column: 0))
    }

    @Test("enabled: BS at column 0 continues onto the wrapped row above")
    func enabledBackspaceCrossesTheWrap() {
        var grid = wrappedGrid()
        grid.reverseWraparoundEnabled = true
        grid.moveCursor(row: 1, column: 0)
        grid.backspace()
        #expect(grid.cursor == Cursor(row: 0, column: 9))
    }

    @Test("enabled: CUB with a count crosses the wrap and keeps moving")
    func enabledCubCrossesTheWrap() {
        var grid = wrappedGrid()
        grid.reverseWraparoundEnabled = true
        grid.moveCursor(row: 1, column: 0)
        // 1 to reach column 9 on row 0, 3 more within that row.
        grid.moveCursorLeft(4)
        #expect(grid.cursor == Cursor(row: 0, column: 6))
    }

    @Test("enabled: a hard newline blocks the wrap — no auto-wrap, no crossing")
    func enabledDoesNotCrossAHardNewline() throws {
        // CR/LF go through `Terminal.feed`, not raw `Grid.write` (which
        // treats every scalar as printable) — this is the actual wire path
        // a program's own newline takes.
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("\\e[?45habc\\r\\n"))
        // Row 0 holds "abc" and was never filled, so it never auto-wrapped —
        // `\r\n` moved the cursor down on purpose, which is not what `?45`
        // undoes.
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 0))
        terminal.grid.backspace()
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 0))
        terminal.grid.moveCursorLeft(5)
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 0))
    }

    @Test("enabled: stops at the top-left corner even with a large count")
    func enabledStopsAtTheScreenTopLeft() {
        var grid = wrappedGrid()
        grid.reverseWraparoundEnabled = true
        grid.moveCursor(row: 1, column: 0)
        grid.moveCursorLeft(1000)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
    }

    @Test("a pending wrap disarms on BS instead of crossing anything")
    func pendingWrapDisarmsFirst() {
        var grid = Grid(rows: 4, columns: 10)
        for scalar in "abcdefghij".unicodeScalars { grid.write(scalar.value) }
        grid.reverseWraparoundEnabled = true
        #expect(grid.pendingWrap)
        grid.backspace()
        #expect(!grid.pendingWrap)
        #expect(grid.cursor == Cursor(row: 0, column: 9))
    }

    // MARK: - Wire form (DECSET/DECRST, DECRQM)

    @Test("CSI ? 45 h / l toggle it")
    func decsetDecrstToggle() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        #expect(!terminal.grid.reverseWraparoundEnabled)
        terminal.feed(try Golden.decode("\\e[?45h"))
        #expect(terminal.grid.reverseWraparoundEnabled)
        terminal.feed(try Golden.decode("\\e[?45l"))
        #expect(!terminal.grid.reverseWraparoundEnabled)
    }

    @Test("RIS resets it")
    func risResetsIt() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("\\e[?45h"))
        #expect(terminal.grid.reverseWraparoundEnabled)
        terminal.feed(try Golden.decode("\\ec"))
        #expect(!terminal.grid.reverseWraparoundEnabled)
    }

    @Test("DECRQM reports ?45 like the other tracked private modes")
    func decrqmReportsIt() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("\\e[?45$p"))
        #expect(String(decoding: terminal.takeOutput(), as: UTF8.self) == "\u{1B}[?45;2$y")
        terminal.feed(try Golden.decode("\\e[?45h\\e[?45$p"))
        #expect(String(decoding: terminal.takeOutput(), as: UTF8.self) == "\u{1B}[?45;1$y")
    }

    @Test("end to end: BS after a wrapped 80-column line lands on its last column")
    func endToEndThroughTheWireForm() throws {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(try Golden.decode("\\e[?45h"))
        terminal.feed(Array("aaaaaaaaaab".utf8))
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 1))
        terminal.feed([0x08])  // BS
        #expect(terminal.grid.cursor == Cursor(row: 1, column: 0))
        terminal.feed([0x08])  // BS again crosses the wrap
        #expect(terminal.grid.cursor == Cursor(row: 0, column: 9))
    }
}
