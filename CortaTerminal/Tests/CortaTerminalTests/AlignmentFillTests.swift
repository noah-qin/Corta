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

/// DECALN fills each row at once rather than writing every cell through
/// `write(_:)`. The expectations below were recorded from the per-cell
/// implementation, so they pin that the fill leaves exactly the grid it did:
/// every cell, flag and side-table reference, not only what the golden dump
/// shows.
@Suite("DECALN fill")
struct AlignmentFillTests {
    /// Wide pairs, a combining cluster, a ZWJ sequence, a lone regional
    /// indicator, a wrapped row, colours, an open hyperlink, a 2–5 region and
    /// a pending wrap, then DECALN, then a combining mark and a letter after it.
    private static let screen =
        "\u{1B}[2;5r\u{1B}[31;44m\u{1B}]8;;https://a.test\u{1B}\\"
        + "世界e\u{301}👩\u{200D}💻\r\nabcdefghijklmnopqrstu\u{1F1E6}"
        + "\u{1B}[6;12Hx"

    private static let after = "\u{1B}#8\u{301}y"

    private func run(_ bytes: String) -> Terminal {
        var terminal = Terminal(rows: 6, columns: 12)
        terminal.feed(Array(bytes.utf8))
        return terminal
    }

    /// Every field of every cell, runs of equal cells folded, plus the state
    /// DECALN resets.
    private func exactState(_ terminal: Terminal) -> String {
        let grid = terminal.grid
        var text = "cursor \(grid.cursor.row),\(grid.cursor.column) wrap \(grid.pendingWrap)"
        text += " margins \(grid.marginTop)-\(grid.marginBottom)"
        text += " pen \(describe(grid.pen.cell(0x45)))\n"
        for row in 0..<grid.rows {
            let line = grid.lines[row]
            text += "\(row) \(line.wrapped ? "W" : "-") n\(line.count):"
            var column = 0
            while column < line.count {
                let cell = line[column]
                var run = 1
                while column + run < line.count, line[column + run] == cell { run += 1 }
                text += " \(describe(cell))x\(run)"
                column += run
            }
            text += "\n"
        }
        return text
    }

    private func describe(_ cell: Cell) -> String {
        String(cell.scalar, radix: 16)
            + "/\(cell.foreground.rawValue)/\(cell.background.rawValue)/\(cell.attributes.rawValue)"
            + "/g\(cell.grapheme.rawValue)/h\(cell.hyperlink.rawValue)/u\(cell.underlineColorID)"
    }

    @Test("DECALN leaves the grid the per-cell fill left")
    func matchesThePerCellFill() {
        let terminal = run(Self.screen + Self.after)
        #expect(exactState(terminal) == """
            cursor 0,2 wrap false margins 0-5 pen 45/0/0/0/g0/h1/u0
            0 - n12: 301/0/0/0/g0/h1/u0x1 79/0/0/0/g0/h1/u0x1 45/0/0/0/g0/h1/u0x10
            1 W n12: 45/0/0/0/g0/h1/u0x12
            2 - n12: 45/0/0/0/g0/h1/u0x12
            3 - n12: 45/0/0/0/g0/h1/u0x12
            4 - n12: 45/0/0/0/g0/h1/u0x12
            5 - n12: 45/0/0/0/g0/h1/u0x12

            """)
    }

    @Test("DECALN in insert mode leaves the grid the per-cell fill left")
    func matchesThePerCellFillInInsertMode() {
        let terminal = run(Self.screen + "\u{1B}[4h" + Self.after)
        #expect(exactState(terminal) == """
            cursor 0,2 wrap false margins 0-5 pen 45/0/0/0/g0/h1/u0
            0 - n12: 301/0/0/0/g0/h1/u0x1 79/0/0/0/g0/h1/u0x1 45/0/0/0/g0/h1/u0x10
            1 - n12: 45/0/0/0/g0/h1/u0x12
            2 - n12: 45/0/0/0/g0/h1/u0x12
            3 - n12: 45/0/0/0/g0/h1/u0x12
            4 - n12: 45/0/0/0/g0/h1/u0x12
            5 - n12: 45/0/0/0/g0/h1/u0x12

            """)
    }

    private func allE(_ terminal: Terminal) -> Bool {
        let row = String(repeating: "E", count: terminal.grid.columns)
        return (0..<terminal.grid.rows).allSatisfy { terminal.grid.rowText($0) == row }
    }

    /// A second DECALN on an untouched screen skips the fill; anything written
    /// in between must still be filled over.
    @Test("DECALN after output fills again")
    func refillsAfterOutput() {
        var terminal = run("\u{1B}#8\u{1B}#8\u{1B}[3;4Hxy\u{1B}[6;1H\n\u{1B}#8")
        #expect(allE(terminal))
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[3;1H\n\u{1B}#8".utf8))
        #expect(allE(terminal))
    }

    /// Rows a resize adds are blank and must be filled, even when the row
    /// count comes back to what it was at the last fill.
    @Test("DECALN after a resize fills the new rows")
    func refillsAfterResize() {
        var terminal = run("\u{1B}[?1049h\u{1B}#8")
        terminal.resize(rows: 3, columns: 12)
        terminal.resize(rows: 6, columns: 12)
        terminal.feed(Array("\u{1B}#8".utf8))
        #expect(allE(terminal))
    }

    /// A fill outside insert mode keeps `wrapped`; one inside it clears it,
    /// even straight after the first.
    @Test("DECALN in insert mode after a plain fill still clears wrapped rows")
    func insertModeClearsWrapAfterAPlainFill() {
        var terminal = run("abcdefghijklmnopq\u{1B}#8")
        #expect(terminal.grid.lines[0].wrapped)
        terminal.feed(Array("\u{1B}[4h\u{1B}#8".utf8))
        #expect(!terminal.grid.lines[0].wrapped)
        #expect(allE(terminal))
    }

    /// The fill is plain narrow cells: nothing of a pair or a cluster survives.
    @Test("DECALN leaves no grapheme, wide or spacer cell behind")
    func leavesPlainCells() {
        let terminal = run(Self.screen + "\u{1B}#8")
        for row in 0..<terminal.grid.rows {
            for column in 0..<terminal.grid.columns {
                let cell = terminal.grid[row, column]
                #expect(cell.scalar == 0x45)
                #expect(cell.grapheme.isNone)
                #expect(!cell.attributes.contains(.wide) && !cell.attributes.contains(.wideSpacer))
            }
        }
    }
}
