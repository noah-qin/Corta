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

/// DECTCEM (`?25`), DECAWM (`?7`), DECOM (`?6`) and CNL/CPL inside a scroll
/// region. All four were missing or partial: a hidden cursor still drew,
/// `?7l` still wrapped, and DECRQM reported the first two "permanently set".
@Suite("Cursor modes")
struct CursorModeTests {
    private func terminal(_ input: String, rows: Int = 6, columns: Int = 10) throws -> Terminal {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(try Golden.decode(input))
        return terminal
    }

    private func response(_ input: String, rows: Int = 6) throws -> String {
        var terminal = try terminal(input, rows: rows)
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    // MARK: - DECTCEM

    @Test("?25l hides the cursor and ?25h shows it")
    func cursorVisibility() throws {
        #expect(try terminal("").grid.isCursorVisible)
        #expect(try !terminal("\\e[?25l").grid.isCursorVisible)
        #expect(try terminal("\\e[?25l\\e[?25h").grid.isCursorVisible)
    }

    @Test("a hidden cursor stays hidden across the alternate screen")
    func cursorVisibilityIsTerminalWide() throws {
        #expect(try !terminal("\\e[?1049h\\e[?25l\\e[?1049l").grid.isCursorVisible)
        #expect(try terminal("\\e[?25l\\e[?1049h\\e[?25h\\e[?1049l").grid.isCursorVisible)
    }

    @Test("RIS and DECSTR show the cursor; DECRC does not restore visibility")
    func cursorVisibilityResets() throws {
        #expect(try terminal("\\e[?25l\\ec").grid.isCursorVisible)
        #expect(try terminal("\\e[?25l\\e[!p").grid.isCursorVisible)
        #expect(try !terminal("\\e7\\e[?25l\\e8").grid.isCursorVisible)
    }

    // MARK: - DECAWM

    @Test("without autowrap the last column is overwritten and nothing wraps")
    func autowrapOff() throws {
        let off = try terminal("\\e[?7labcdefghijXYZ")
        #expect(off.grid.rowText(0) == "abcdefghiZ")
        #expect(off.grid.rowText(1) == "")
        #expect(off.grid.cursor == Cursor(row: 0, column: 9))
        #expect(!off.grid.line(0).wrapped)
        // The same, one byte at a time through the generic path.
        var bytewise = Terminal(rows: 6, columns: 10)
        for byte in try Golden.decode("\\e[?7labcdefghijXYZ") { bytewise.feed(CollectionOfOne(byte)) }
        #expect(bytewise.grid.rowText(0) == "abcdefghiZ")
    }

    @Test("?7l disarms a pending wrap, and ?7h wraps again")
    func autowrapToggles() throws {
        #expect(try terminal("abcdefghij\\e[?7lX").grid.rowText(0) == "abcdefghiX")
        let on = try terminal("\\e[?7l\\e[?7habcdefghijX")
        #expect(on.grid.rowText(1) == "X")
    }

    @Test("without autowrap a wide character never splits at the margin")
    func autowrapOffWide() throws {
        let grid = try terminal("\\e[?7labcdefghi\u{4E2D}").grid
        #expect(grid.rowText(0) == "abcdefghi")
        #expect(grid.rowText(1) == "")
        // One that fits still lands, ending in the last column.
        #expect(try terminal("\\e[?7labcdefgh\u{4E2D}").grid.rowText(0) == "abcdefgh\u{4E2D}")
    }

    // MARK: - DECOM

    @Test("origin mode addresses from the region's top and stays inside it")
    func originModeAddressing() throws {
        // Region rows 2–4 (one-based); DECOM homes to its top.
        let homed = try terminal("\\e[2;4r\\e[?6h")
        #expect(homed.grid.cursor == Cursor(row: 1, column: 0))
        #expect(try terminal("\\e[2;4r\\e[?6h\\e[2;3H").grid.cursor == Cursor(row: 2, column: 2))
        #expect(try terminal("\\e[2;4r\\e[?6h\\e[99;1H").grid.cursor == Cursor(row: 3, column: 0))
        #expect(try terminal("\\e[2;4r\\e[?6h\\e[3d").grid.cursor.row == 3)
        // Leaving DECOM homes to the screen's corner.
        #expect(try terminal("\\e[2;4r\\e[?6h\\e[3;3H\\e[?6l").grid.cursor == Cursor())
    }

    @Test("a position report under origin mode counts from the region")
    func originModeReports() throws {
        #expect(try response("\\e[2;4r\\e[?6h\\e[2;3H\\e[6n") == "\u{1B}[2;3R")
        #expect(try response("\\e[2;4r\\e[?6h\\e[2;3H\\e[?6n") == "\u{1B}[?2;3;1R")
        #expect(try response("\\e[2;4r\\e[2;3H\\e[6n") == "\u{1B}[2;3R")
    }

    @Test("DECSTBM homes to the region under origin mode")
    func originModeScrollRegionHomes() throws {
        #expect(try terminal("\\e[?6h\\e[3;5r").grid.cursor == Cursor(row: 2, column: 0))
        #expect(try terminal("\\e[3;5r").grid.cursor == Cursor())
    }

    @Test("DECSC saves origin mode, and DECSTR clears it")
    func originModeSaveRestore() throws {
        let restored = try terminal("\\e[2;4r\\e[?6h\\e7\\e[?6l\\e8")
        #expect(restored.grid.originMode)
        #expect(try !terminal("\\e[2;4r\\e[?6h\\e[!p").grid.originMode)
    }

    // MARK: - CNL / CPL

    @Test("CNL and CPL stop at the scroll region's margins, as CUD and CUU do")
    func lineMovesRespectMargins() throws {
        #expect(try terminal("\\e[2;4r\\e[3;5H\\e[9E").grid.cursor == Cursor(row: 3, column: 0))
        #expect(try terminal("\\e[2;4r\\e[3;5H\\e[9F").grid.cursor == Cursor(row: 1, column: 0))
        // Outside the region they run to the screen's edge.
        #expect(try terminal("\\e[2;4r\\e[6;5H\\e[9F").grid.cursor == Cursor(row: 0, column: 0))
    }
}
