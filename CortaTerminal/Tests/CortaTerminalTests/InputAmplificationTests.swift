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
