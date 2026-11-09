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

import Testing

@testable import CortaTerminal

/// The alternate screen (`?1049`), driven through the grid API.
@Suite("Alternate screen")
struct AlternateScreenTests {
    @Test("a deferred alternate-screen exit consumes no bytes after DECRST")
    func sessionFeedStopsBeforeReturningToMain() {
        var terminal = Terminal(rows: 3, columns: 12)
        terminal.feed(Array("main\u{1B}[?1049h".utf8))
        terminal.resize(rows: 3, columns: 8)
        let control = Array("\u{1B}[?1049l".utf8)
        let bytes = control + Array("tail".utf8)
        let consumed = terminal.feedDeferringImageDecode(bytes[...])
        #expect(consumed == control.count)
        #expect(terminal.grid.isAlternateScreenActive)
        #expect(terminal.hasDeferredAlternateScreenExit)
        var prepared = terminal.grid
        prepared.exitAlternateScreen()
        terminal.completeDeferredAlternateScreenExit(prepared)
        terminal.feed(bytes[consumed...])
        #expect(!terminal.hasDeferredAlternateScreenExit)
        #expect(!terminal.grid.isAlternateScreenActive)
        #expect(terminal.grid[0, 4].scalar == 0x74)
    }

    @Test("Clear History on the alternate screen clears the main screen's history too, and counts it first")
    func clearHistoryOnTheAlternateScreenReachesTheMainScreen() {
        var terminal = Terminal(rows: 3, columns: 12, scrollbackLimit: 100)
        terminal.feed(Array((0..<8).map { "line\($0)" }.joined(separator: "\r\n").utf8))
        let history = terminal.grid.scrollback.count
        #expect(history > 0)
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.grid.scrollback.count == 0)
        #expect(terminal.grid.clearableHistoryLineCount == history)
        terminal.grid.clearAllHistory()
        #expect(terminal.grid.clearableHistoryLineCount == 0)
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.grid.scrollback.count == 0)
    }

    @Test("ED 3 from a program on the alternate screen leaves the main screen's history")
    func eraseSavedLinesOnTheAlternateScreenKeepsMainHistory() {
        var terminal = Terminal(rows: 3, columns: 12, scrollbackLimit: 100)
        terminal.feed(Array((0..<8).map { "line\($0)" }.joined(separator: "\r\n").utf8))
        let history = terminal.grid.scrollback.count
        terminal.feed(Array("\u{1B}[?1049h\u{1B}[3J\u{1B}[?1049l".utf8))
        #expect(terminal.grid.scrollback.count == history)
    }

    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    /// xterm ctlseqs, Ps = 1049: on set — save cursor, switch to the
    /// alternate screen, clear it.
    @Test("entering switches to a fresh blank screen and homes the cursor")
    func enteringSwitchesToABlankScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.moveCursor(row: 2, column: 5)

        grid.enterAlternateScreen()

        #expect(grid.isAlternateScreenActive)
        #expect(grid.cursor == Cursor(row: 0, column: 0))
        for row in 0..<3 { #expect(grid.line(row).isEmpty) }
    }

    /// xterm ctlseqs, Ps = 1049: on reset — switch back and restore the
    /// cursor saved on the way in.
    @Test("exiting restores the main screen and the saved cursor")
    func exitingRestoresMainScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.moveCursor(row: 2, column: 5)

        grid.enterAlternateScreen()
        write("ALT", to: &grid)
        grid.exitAlternateScreen()

        #expect(!grid.isAlternateScreenActive)
        #expect(grid.cursor == Cursor(row: 2, column: 5))
        #expect(grid[0, 0].scalar == 0x6D)  // "m"
        #expect(grid[0, 3].scalar == 0x6E)  // "n"
        #expect(grid.line(1).isEmpty)
    }

    /// A private mode set by the program is terminal-wide state, not part
    /// of either screen's own content — `exitAlternateScreen` restores the
    /// parked main screen wholesale, and without carrying the mode across
    /// explicitly (the same way `cursorStyle` already is) a `?45` a full-
    /// screen child set would be silently discarded on exit.
    @Test("reverse-wraparound mode survives an alternate-screen round trip")
    func reverseWraparoundSurvivesAlternateScreen() {
        var grid = Grid(rows: 3, columns: 8)
        grid.reverseWraparoundEnabled = true

        grid.enterAlternateScreen()
        #expect(grid.reverseWraparoundEnabled)

        grid.exitAlternateScreen()
        #expect(grid.reverseWraparoundEnabled)
    }

    /// The mode can also change *while* the alternate screen is active —
    /// e.g. `tmux` or `less` setting it for their own full-screen UI — and
    /// that value, not whatever the main screen had before entering, is
    /// what must survive the exit.
    @Test("a mode change made while the alternate screen is active survives exiting it")
    func modeChangedDuringAlternateScreenSurvivesExit() {
        var grid = Grid(rows: 3, columns: 8)
        #expect(!grid.reverseWraparoundEnabled)

        grid.enterAlternateScreen()
        grid.reverseWraparoundEnabled = true
        grid.exitAlternateScreen()

        #expect(grid.reverseWraparoundEnabled)
    }

    /// An alternate screen has no history: lines scrolled
    /// while it is live are discarded, not pushed to the main scrollback.
    @Test("the alternate screen has no scrollback")
    func alternateScreenHasNoScrollback() {
        var grid = Grid(rows: 2, columns: 8)
        write("one", to: &grid)
        grid.lineFeed()
        grid.carriageReturn()
        write("two", to: &grid)
        grid.lineFeed()  // "one" enters history
        #expect(grid.scrollback.count == 1)

        grid.enterAlternateScreen()
        for _ in 0..<10 { grid.lineFeed() }  // scrolls on the alt screen
        #expect(grid.scrollback.isEmpty)

        grid.exitAlternateScreen()
        #expect(grid.scrollback.count == 1)
        #expect(grid.scrollback[0][0].scalar == 0x6F)  // "o" of "one"
    }

    /// Exiting without entering, like any unpaired reset, is a no-op.
    @Test("exiting while the main screen is live does nothing")
    func exitingWithoutEnteringIsIgnored() {
        var grid = Grid(rows: 2, columns: 8)
        write("main", to: &grid)
        grid.exitAlternateScreen()
        #expect(!grid.isAlternateScreenActive)
        #expect(grid[0, 0].scalar == 0x6D)
    }

    /// A second `?1049 h` while already active clears again but keeps the
    /// original main screen parked — the first switch is the one that
    /// matters.
    @Test("entering twice parks the main screen once")
    func enteringTwiceParksMainOnce() {
        var grid = Grid(rows: 2, columns: 8)
        write("main", to: &grid)
        grid.enterAlternateScreen()
        write("junk", to: &grid)
        grid.enterAlternateScreen()
        write("more", to: &grid)
        grid.exitAlternateScreen()

        #expect(!grid.isAlternateScreenActive)
        #expect(grid[0, 0].scalar == 0x6D)
        #expect(grid[0, 3].scalar == 0x6E)
    }

    /// The size belongs to the window, not to a screen: a resize while the
    /// alternate screen is live is adopted by the main screen on the way
    /// back.
    @Test("a resize during the alternate screen is adopted on exit")
    func resizeDuringAlternateScreen() {
        var grid = Grid(rows: 3, columns: 8)
        write("main", to: &grid)
        grid.enterAlternateScreen()
        grid.resize(rows: 2, columns: 4)
        grid.exitAlternateScreen()

        #expect(grid.rows == 2)
        #expect(grid.columns == 4)
        #expect(grid[0, 0].scalar == 0x6D)
    }
    /// The alternate screen does not reflow, and a narrower one kept every
    /// cell past the new margin: invisible, yet copied and searched.
    @Test("narrowing the alternate screen cuts rows to the new width")
    func narrowingTruncatesAlternateRows() {
        var terminal = Terminal(rows: 3, columns: 10)
        terminal.feed(Array("\u{1B}[?1049habcdefg\u{4E2D}\r\n0123456789".utf8))
        terminal.resize(rows: 3, columns: 8)
        #expect(terminal.grid.line(0).count <= 8)
        #expect(terminal.grid.rowText(0) == "abcdefg")
        #expect(terminal.grid.rowText(1) == "01234567")
        // A cut pair leaves no lone lead behind.
        let row = terminal.grid.line(0)
        #expect(!(0..<row.count).contains { row[$0].attributes.contains(.wide) })
    }
}
