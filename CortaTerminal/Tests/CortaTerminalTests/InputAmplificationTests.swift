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

import Foundation
import Testing

@testable import CortaTerminal

/// Output that costs the child a few bytes and the terminal far more: each
/// test feeds the cheap sequence and bounds the work or memory it may buy
/// (`SECURITY.md` §3).
@Suite("Input amplification")
struct InputAmplificationTests {
    @Test("huge tab counts stop at the margin and allow following output")
    func tabCountsStopAtMargins() {
        var terminal = Terminal(rows: 2, columns: 80)
        let start = ContinuousClock.now
        for _ in 0..<2_000 {
            terminal.feed(Array("\u{1B}[65535I\u{1B}[65535Z".utf8))
        }
        #expect(terminal.grid.cursor.column == 0)
        terminal.feed(Array("ok".utf8))
        #expect(terminal.grid.rowText(0).hasPrefix("ok"))
        #expect(ContinuousClock.now - start < .seconds(1))

        for columns in [1, 17, 80] {
            var grid = Grid(rows: 2, columns: columns)
            grid.clearTabStop(atCursorOnly: false)
            grid.tabForward(Int.max)
            #expect(grid.cursor.column == columns - 1)
            grid.tabBackward(Int.max)
            #expect(grid.cursor.column == 0)
        }
        var grid = Grid(rows: 2, columns: 30)
        grid.tabForward(0)
        #expect(grid.cursor.column == 8)
        grid.tabForward(2)
        #expect(grid.cursor.column == 24)
        grid.tabBackward(2)
        #expect(grid.cursor.column == 8)
    }

    @Test("a run of combining marks keeps a bounded cluster")
    func combiningRunIsCapped() throws {
        var terminal = Terminal(rows: 4, columns: 20)
        var input = Array("a".utf8)
        for _ in 0..<1_000 { input += Array("\u{0301}".utf8) }
        terminal.feed(input)

        let cell = terminal.grid.line(0)[0]
        let cluster = try #require(terminal.grid.graphemes.scalars(for: cell.grapheme))
        #expect(cluster.count == GraphemeTable.maximumClusterScalars)
        #expect(cluster.first == 0x61)
        // One entry per accepted mark, not one per mark sent.
        #expect(terminal.grid.graphemes.count < GraphemeTable.maximumClusterScalars)
    }

    @Test("a full cluster ending in a joiner does not swallow the characters after it")
    func fullJoinerClusterLetsTextContinue() throws {
        var terminal = Terminal(rows: 4, columns: 40)
        // 👩‍ repeated: alternating emoji and ZWJ, 32 scalars ending in ZWJ.
        var cluster = ""
        for _ in 0..<(GraphemeTable.maximumClusterScalars / 2) { cluster += "\u{1F469}\u{200D}" }
        terminal.feed(Array((cluster + "\u{1F600}é").utf8))

        let first = try #require(terminal.grid.graphemes.scalars(for: terminal.grid.line(0)[0].grapheme))
        #expect(first.count == GraphemeTable.maximumClusterScalars)
        #expect(first.last == 0x200D)
        // The emoji after it is its own wide cell, and é follows it.
        #expect(terminal.grid.line(0)[2].scalar == 0x1F600)
        #expect(terminal.grid.line(0)[4].scalar == 0xE9)
    }

    @Test("a full cluster ending in a lone regional indicator does not swallow the ones after it")
    func fullIndicatorClusterLetsTextContinue() {
        var terminal = Terminal(rows: 4, columns: 40)
        // x, an accent, then 15 × (ZWJ, indicator): 32 scalars ending in one
        // indicator — reachable only through joiners, since a flag pair ends
        // a run at two.
        var input = "x\u{0301}"
        for _ in 0..<15 { input += "\u{200D}\u{1F1FA}" }
        input += "\u{1F1FA}\u{1F1F8}"  // then a flag
        terminal.feed(Array(input.utf8))
        let indicators = terminal.grid.rowText(0).unicodeScalars.filter {
            (0x1F1E6...0x1F1FF).contains($0.value)
        }.count
        #expect(indicators == 17, "the flag after a full cluster was dropped")
    }

    @Test("a hyperlink table full of live links is not rescanned for every new link")
    func futileHyperlinkSweepsAreRationed() {
        // Every link on its own scrollback row, so all stay live.
        var terminal = Terminal(rows: 4, columns: 20, scrollbackLimit: 4_000)
        var input: [UInt8] = []
        for index in 0..<HyperlinkTable.capacity {
            input += Array("\u{1B}]8;;https://live.test/\(index)\u{1B}\\x\u{1B}]8;;\u{1B}\\\r\n".utf8)
        }
        terminal.feed(input)
        #expect(terminal.grid.hyperlinks.count == HyperlinkTable.capacity)

        input = []
        for index in 0..<1_000 {
            input += Array("\u{1B}]8;;https://new.test/\(index)\u{1B}\\y\u{1B}]8;;\u{1B}\\\r\n".utf8)
        }
        terminal.feed(input)
        // Unrationed, every one of the 1 000 scanned the whole grid.
        #expect(terminal.grid.sideTableSweeps <= 3)
    }

    @Test("a placement asking for thousands of rows scrolls at most a region and a screen")
    func placementScrollIsCapped() {
        var terminal = Terminal(rows: 10, columns: 40, scrollbackLimit: 10_000)
        terminal.grid.cellPixelWidth = 10
        terminal.grid.cellPixelHeight = 20
        let pixel = Data(repeating: 0xFF, count: 4).base64EncodedString()
        terminal.feed(Array("\u{1B}_Ga=t,q=2,f=32,s=1,v=1,i=1;\(pixel)\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[10;1H".utf8))

        for _ in 0..<20 {
            terminal.feed(Array("\u{1B}_Ga=p,q=2,i=1,r=4096\u{1B}\\".utf8))
        }
        // 20 placements × (region 10 + screen 10), not 20 × 4096.
        #expect(terminal.grid.scrollback.totalPushed <= 20 * 20)
    }

    @Test("placement ids are per image: the same p= on two images is two placements")
    func placementIDsArePerImage() {
        var terminal = Terminal(rows: 10, columns: 40)
        let pixel = Data(repeating: 0xFF, count: 4).base64EncodedString()
        for image in 1...2 {
            terminal.feed(
                Array("\u{1B}_Ga=T,q=2,f=32,s=1,v=1,i=\(image),p=1,C=1;\(pixel)\u{1B}\\".utf8))
        }
        let placed = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placed.map(\.imageID.rawValue) == [1, 2])

        // Deleting one image's placement 1 leaves the other image's.
        terminal.feed(Array("\u{1B}_Ga=d,d=i,i=1,p=1,q=2\u{1B}\\".utf8))
        #expect(terminal.grid.imagePlacements.orderedPlacements().map(\.imageID.rawValue) == [2])
    }

    @Test("the span walk reads wrap flags the same as whole rows do")
    func wrapFlagLookupMatchesRows() {
        var terminal = Terminal(rows: 3, columns: 5, scrollbackLimit: 50)
        terminal.feed(Array("aaaaaaaaaaaaaaaaaaaaaa\r\nbb\r\ncccccccccccc\r\nd".utf8))
        let grid = terminal.grid
        for row in -grid.scrollback.count - 1...grid.rows {
            #expect(grid.isDocumentLineWrapped(row) == grid.documentLine(row).wrapped, "row \(row)")
        }
        let span = grid.logicalLineRowSpan(containing: -grid.scrollback.count)
        #expect(span.first == -grid.scrollback.count)
        #expect(span.last - span.first + 1 == 5, "22 cells at 5 columns")
    }
}
