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

/// The serialiser every golden test is read through.
///
/// The expectations here are written by hand. If the dump format changes,
/// these are the files to edit first; the goldens follow.
@Suite("Grid dump")
struct GridDumpTests {
    private func write(_ text: String, to grid: inout Grid) {
        for scalar in text.unicodeScalars { grid.write(scalar.value) }
    }

    @Test("a plain grid dumps to a padded, delimited block")
    func plainGridDump() {
        var grid = Grid(rows: 3, columns: 10)
        write("abc", to: &grid)
        grid.moveCursor(row: 1, column: 3)

        #expect(
            grid.dump() == """
                rows: 3 columns: 10
                cursor: row 1 column 3
                   0 |abc       |
                   1 |          |
                   2 |          |

                """)
    }

    /// The style layer names each distinct rendition once and marks default
    /// cells with a dot, so a colour change is visible without reading the
    /// character layer.
    @Test("styles dump as a parallel layer with a legend")
    func styledGridDump() {
        var grid = Grid(rows: 2, columns: 8)
        grid.pen.foreground = .indexed(1)
        grid.pen.attributes = .bold
        write("ab", to: &grid)
        grid.pen = Pen()
        write("c", to: &grid)
        grid.pen.background = .rgb(0, 128, 255)
        write("d", to: &grid)

        #expect(
            grid.dump() == """
                rows: 2 columns: 8
                cursor: row 0 column 4
                   0 |abcd    |
                   1 |        |
                styles:
                   0 |AA.B....|
                   1 |........|
                   A = fg:1 bg:default attrs:bold
                   B = fg:default bg:rgb(0,128,255) attrs:none

                """)
    }

    @Test("a soft-wrapped row is marked, an armed wrap is noted on the cursor")
    func wrapIsVisibleInTheDump() {
        var grid = Grid(rows: 2, columns: 4)
        write("abcd", to: &grid)

        #expect(
            grid.dump() == """
                rows: 2 columns: 4
                cursor: row 0 column 3 wrap-pending
                   0 |abcd|
                   1 |    |

                """)

        write("e", to: &grid)
        #expect(
            grid.dump() == """
                rows: 2 columns: 4
                cursor: row 1 column 1
                   0 |abcd| wrapped
                   1 |e   |

                """)
    }
}
