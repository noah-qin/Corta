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

import CortaTerminal
import Testing
@testable import Corta

struct AgentScreenPreviewTests {
    @Test func takesTheLastTenNonblankRowsAndAtMostOneHundredColumns() {
        var terminal = Terminal(rows: 30, columns: 200)
        for row in 0..<12 {
            terminal.feed(Array(("row \(row)   \r\n\r\n").utf8))
        }
        terminal.feed(Array((String(repeating: "x", count: 100) + "over the edge").utf8))
        let expected = (3..<12).map { "row \($0)" } + [String(repeating: "x", count: 100)]
        #expect(AgentScreenPreview.lines(in: terminal.grid) == expected)
    }

    @Test func dropsAPartialWideCellAndKeepsAWholePair() {
        var terminal = Terminal(rows: 3, columns: 120)
        let prefix = String(repeating: "x", count: 98)
        terminal.feed(Array((prefix + "界!\r\n" + prefix + "x界!").utf8))
        #expect(AgentScreenPreview.lines(in: terminal.grid) == [prefix + "界", prefix + "x"])
    }

    @Test func cleansControlsAndConcealingScalarsAndSkipsInvisibleCells() throws {
        var terminal = Terminal(rows: 2, columns: 30)
        terminal.feed(Array("A\u{1B}[8mX\u{1B}[0mB e\u{301}".utf8))
        var grid = terminal.grid
        #expect(AgentScreenPreview.lines(in: grid) == ["A B e\u{301}"])

        // Inject raw scalars into the interned cell, after the parser's own cleaning.
        var graphemes = GraphemeTable()
        let injectedID = graphemes.intern([0x65, 0x202E, 0x9B, 0x1B, 0x301, 0x2028, 0x2029])
        let id = try #require(injectedID)
        #expect(grid[0, 4].grapheme == id)
        grid.graphemes = graphemes
        #expect(AgentScreenPreview.lines(in: grid) == ["A B e\u{301}"])
    }

    @Test func readsOnlyTheActiveScreenAndReturnsNothingAfterClear() {
        var terminal = Terminal(rows: 5, columns: 30)
        #expect(AgentScreenPreview.lines(in: terminal.grid).isEmpty)
        terminal.feed(Array("Main screen\u{1B}[?1049hAllow tool use?\r\n  1. Yes\r\n  2. No".utf8))
        #expect(AgentScreenPreview.lines(in: terminal.grid) == ["Allow tool use?", "  1. Yes", "  2. No"])
        terminal.feed(Array("\u{1B}[2J".utf8))
        #expect(AgentScreenPreview.lines(in: terminal.grid).isEmpty)
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(AgentScreenPreview.lines(in: terminal.grid) == ["Main screen"])
    }
}
