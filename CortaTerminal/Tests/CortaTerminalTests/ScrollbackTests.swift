import Testing

@testable import CortaTerminal

/// M1.14 — the scrollback ring buffer.
@Suite("Scrollback")
struct ScrollbackTests {
    private func line(_ text: String) -> Line {
        var line = Line()
        for (column, scalar) in text.unicodeScalars.enumerated() {
            line[column] = Cell(scalar: scalar.value)
        }
        return line
    }

    private func text(_ line: Line) -> String {
        var text = ""
        for column in 0..<line.count {
            text.unicodeScalars.append(Unicode.Scalar(line[column].scalar) ?? "?")
        }
        return text
    }

    @Test("history reads oldest first")
    func historyReadsOldestFirst() {
        var scrollback = Scrollback(limit: 4)
        for index in 0..<3 { scrollback.push(line("line\(index)")) }
        #expect(scrollback.count == 3)
        #expect(!scrollback.isFull)
        #expect(text(scrollback[0]) == "line0")
        #expect(text(scrollback[2]) == "line2")
        #expect(scrollback[3].isEmpty)
        #expect(scrollback[-1].isEmpty)
    }

    /// The requirement from the roadmap: 10,000 lines into a 1,000-line
    /// scrollback, evicting in O(1) and never growing past the cap.
    @Test("ten thousand lines into a thousand-line ring stay bounded")
    func evictionIsBoundedAndInOrder() {
        var scrollback = Scrollback(limit: 1_000)
        let width = 80
        for index in 0..<10_000 {
            scrollback.push(line(String(repeating: "x", count: width - 6) + String(format: "%06d", index)))
        }

        #expect(scrollback.count == 1_000)
        #expect(scrollback.isFull)
        // The batch FIFO stays bounded by the cap, not by how many lines
        // were ever pushed: 10,000 pushes into a 1,000-line, batch-size-256
        // scrollback should never carry more than a handful of live batches.
        #expect(scrollback.batchCount <= 6)

        // And the ceiling on stored cells is the cap times the row width,
        // not the number of lines ever written.
        let cells = (0..<scrollback.count).reduce(0) { $0 + scrollback[$1].count }
        #expect(cells == 1_000 * width)

        // The window is the last thousand, oldest first.
        #expect(text(scrollback[0]).hasSuffix("009000"))
        #expect(text(scrollback[999]).hasSuffix("009999"))
    }

    @Test("a zero-line cap keeps nothing and does not trap")
    func zeroLimitKeepsNothing() {
        var scrollback = Scrollback(limit: 0)
        for _ in 0..<100 { scrollback.push(line("x")) }
        #expect(scrollback.count == 0)
        #expect(scrollback.isEmpty)
        #expect(scrollback[0].isEmpty)
    }

    /// Rows sit in history untouched for a long time, so trailing blanks are
    /// paid for once, here (`DESIGN.md` §2.3).
    @Test("rows are trimmed on the way into history")
    func rowsAreTrimmed() {
        var padded = line("hi")
        padded[40] = .blank
        #expect(padded.count == 41)

        var scrollback = Scrollback(limit: 4)
        scrollback.push(padded)
        #expect(scrollback[0].count == 2)
    }

    @Test("clearing history releases the lines but keeps the allocation")
    func clearingHistory() {
        var scrollback = Scrollback(limit: 4)
        for index in 0..<4 { scrollback.push(line("line\(index)")) }
        scrollback.removeAll()
        #expect(scrollback.count == 0)
        #expect(scrollback[0].isEmpty)

        scrollback.push(line("after"))
        #expect(text(scrollback[0]) == "after")
    }
    /// M6.10 — `count` saturates at the limit, so it cannot say how far the
    /// document has moved once the ring is full. `totalPushed` can.
    @Test("totalPushed keeps counting after the ring is full")
    func totalPushedIsMonotonic() {
        var scrollback = Scrollback(limit: 4)
        for index in 0..<10 { scrollback.push(line("line\(index)")) }
        #expect(scrollback.count == 4)
        #expect(scrollback.totalPushed == 10)
    }
}

/// M1.14 — the grid's side of it.
@Suite("Grid scrollback")
struct GridScrollbackTests {
    private func terminal(_ source: String, rows: Int, columns: Int, limit: Int) throws
        -> Terminal
    {
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: limit)
        terminal.feed(try Golden.decode(source))
        return terminal
    }

    @Test("a line feed at the bottom pushes the top row into history")
    func lineFeedAtTheBottomScrolls() throws {
        let terminal = try self.terminal(
            "one\\r\\ntwo\\r\\nthree\\r\\n", rows: 2, columns: 8, limit: 10)
        #expect(terminal.grid.scrollback.count == 2)
        #expect(terminal.grid.scrollback[0][0].scalar == 0x6F)  // "one"
        #expect(terminal.grid.scrollback[1][0].scalar == 0x74)  // "two"
        #expect(terminal.grid[0, 0].scalar == 0x74)  // "three" on screen
    }

    /// A command that soft-wrapped before it scrolled is still one logical
    /// line once it is in history, or selecting it later inserts a newline
    /// that was never typed (`DESIGN.md` §2.1).
    @Test("the wrap flag survives into history")
    func wrapFlagSurvivesScrolling() throws {
        let terminal = try self.terminal("abcdefgh\\r\\nx\\r\\ny", rows: 2, columns: 4, limit: 10)
        // "abcdefgh" filled two rows: the first is soft wrapped.
        #expect(terminal.grid.scrollback.count >= 2)
        #expect(terminal.grid.scrollback[0].wrapped)
        #expect(!terminal.grid.scrollback[1].wrapped)
    }

    /// xterm's ED 3. tmux and clear(1) both send it.
    @Test("ED 3 discards the history and leaves the screen")
    func eraseDisplayThreeClearsHistory() throws {
        var terminal = try self.terminal(
            "one\\r\\ntwo\\r\\nthree\\r\\n", rows: 2, columns: 8, limit: 10)
        #expect(terminal.grid.scrollback.count == 2)

        terminal.feed(try Golden.decode("\\e[3J"))
        #expect(terminal.grid.scrollback.count == 0)
        #expect(terminal.grid[0, 0].scalar == 0x74)
    }

    @Test("flooding a small screen leaves the last lines and a full ring")
    func floodingStaysBounded() throws {
        var terminal = Terminal(rows: 4, columns: 20, scrollbackLimit: 100)
        for index in 0..<10_000 {
            terminal.feed(Array("line \(index)\r\n".utf8))
        }
        #expect(terminal.grid.scrollback.count == 100)
        #expect(terminal.grid.scrollback.isFull)
        // The screen holds the tail; 9999 is on the row above the cursor.
        #expect(terminal.grid.cursor == Cursor(row: 3, column: 0))
        let lastRow = terminal.grid.line(2)
        var text = ""
        for column in 0..<lastRow.count {
            text.unicodeScalars.append(Unicode.Scalar(lastRow[column].scalar) ?? "?")
        }
        #expect(text == "line 9999")
    }
}
