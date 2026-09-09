import Testing

@testable import CortaTerminal

/// Two sequences `esctest` found missing (Q01), both of which matter for a
/// reason other than the one they were designed for.
@Suite("DECALN and DECID")
struct AlignmentAndIdentityTests {
    private func feed(_ bytes: String, rows: Int = 4, columns: Int = 8) -> Terminal {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(Array(bytes.utf8))
        return terminal
    }

    private func rowText(_ terminal: Terminal, _ row: Int) -> String {
        terminal.grid.rowText(row)
    }

    // MARK: - DECALN (ESC # 8)

    /// The whole screen, not the scroll region and not from the cursor down.
    @Test("DECALN fills every cell with E")
    func fillsTheScreen() {
        let terminal = feed("hello\u{1B}#8")
        for row in 0..<4 {
            #expect(rowText(terminal, row) == "EEEEEEEE", "row \(row)")
        }
    }

    /// The failure `esctest` actually reported: the fill happened elsewhere
    /// but the cursor stayed where it was.
    @Test("DECALN homes the cursor")
    func homesTheCursor() {
        let terminal = feed("\u{1B}[3;5Hx\u{1B}#8")
        #expect(terminal.grid.cursor.row == 0)
        #expect(terminal.grid.cursor.column == 0)
    }

    /// A program that set a region and then asked for a known screen gets a
    /// known screen, including the margins it will scroll within next.
    @Test("DECALN resets the scroll region")
    func resetsTheMargins() {
        var terminal = Terminal(rows: 4, columns: 8)
        terminal.feed(Array("\u{1B}[2;3r".utf8))
        terminal.feed(Array("\u{1B}#8".utf8))
        // With the margins reset, a full-screen scroll moves every row and
        // pushes the top one into the scrollback; a 2..3 region would not.
        terminal.feed(Array("\u{1B}[4;1H\n".utf8))
        #expect(terminal.grid.scrollback.count == 1)
    }

    /// The screen is uniform, which is the point of it. A fill in whatever
    /// colour the last SGR left behind is not a known state.
    @Test("DECALN fills with the default pen, not the current one")
    func fillsWithTheDefaultPen() {
        let terminal = feed("\u{1B}[31;44m\u{1B}#8")
        let cell = terminal.grid[0, 0]
        #expect(cell.foreground == Cell().foreground)
        #expect(cell.background == Cell().background)
    }

    /// Charset designation is the other `ESC` form carrying an intermediate,
    /// and it stays ignored: `ESC ( B` must not paint the screen.
    @Test("another intermediate form is still ignored cleanly")
    func charsetDesignationIsUnaffected() {
        let terminal = feed("ab\u{1B}(B")
        #expect(rowText(terminal, 0).hasPrefix("ab"))
    }

    // MARK: - DECID (ESC Z)

    /// It was silent. A query that goes unanswered is worse than one that is
    /// refused: the client waits rather than falling back — the same shape as
    /// the fish hang the workflow harness hit (U10).
    @Test("DECID answers, and answers exactly as Primary DA does")
    func decidAnswersLikePrimaryDA() {
        var byEscZ = Terminal(rows: 4, columns: 8)
        byEscZ.feed(Array("\u{1B}Z".utf8))
        var byCSI = Terminal(rows: 4, columns: 8)
        byCSI.feed(Array("\u{1B}[c".utf8))
        let answer = byEscZ.takeOutput()
        #expect(!answer.isEmpty)
        #expect(answer == byCSI.takeOutput())
        #expect(String(decoding: answer, as: UTF8.self) == "\u{1B}[?62;1;22c")
    }
}
