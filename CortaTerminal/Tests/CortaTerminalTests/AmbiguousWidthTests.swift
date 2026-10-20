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

/// `ambiguous-width`: East Asian Ambiguous scalars (UAX #11) take one cell,
/// or two when the window says wide.
struct AmbiguousWidthTests {
    @Test("Ambiguous is one cell by default")
    func narrowByDefault() {
        var grid = Grid(rows: 2, columns: 10)
        grid.write(0x00B1)  // ±
        #expect(grid.cursor.column == 1)
    }

    @Test("wide makes Ambiguous two cells, and only Ambiguous")
    func wideWhenSet() {
        var grid = Grid(rows: 2, columns: 10)
        grid.ambiguousIsWide = true
        grid.write(0x00B1)  // ±, Ambiguous
        #expect(grid.cursor.column == 2)
        #expect(grid[0, 0].attributes.contains(.wide))
        grid.write(0x0041)  // A, Narrow
        #expect(grid.cursor.column == 3)
        grid.write(0x00E9)  // é, Ambiguous
        #expect(grid.cursor.column == 5)
        grid.write(0x0101)  // ā, Ambiguous
        #expect(grid.cursor.column == 7)
        grid.write(0x0410)  // А, Cyrillic, Ambiguous
        #expect(grid.cursor.column == 9)
    }

    /// Zero width wins: a combining mark that is also Ambiguous stays on
    /// its base.
    @Test("an Ambiguous combining mark stays zero-width")
    func combiningMarkStaysZeroWidth() {
        var grid = Grid(rows: 2, columns: 10)
        grid.ambiguousIsWide = true
        grid.write(0x0065)  // e
        grid.write(0x0301)  // combining acute, Mn and Ambiguous
        #expect(grid.cursor.column == 1)
    }

    /// A setting of the window: the alternate screen and a full reset keep
    /// it.
    @Test("the setting survives the alternate screen and RIS")
    func survivesScreensAndReset() {
        var grid = Grid(rows: 2, columns: 10)
        grid.ambiguousIsWide = true
        grid.enterAlternateScreen()
        #expect(grid.ambiguousIsWide)
        grid.exitAlternateScreen()
        #expect(grid.ambiguousIsWide)
        grid.resetToInitialState()
        #expect(grid.ambiguousIsWide)
    }

    @Test("the generated table is sorted and non-overlapping")
    func tableIsSorted() {
        for (previous, next) in zip(ambiguousWidthRanges, ambiguousWidthRanges.dropFirst()) {
            #expect(previous.upperBound < next.lowerBound)
        }
        #expect(Grid.isAmbiguous(0x00B1))
        #expect(!Grid.isAmbiguous(0x0041))
        #expect(!Grid.isAmbiguous(0x4E2D))
    }
}
