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

struct RowRecyclingTests {
    @Test(arguments: [false, true]) func evictedBufferIsReused(partial: Bool) {
        var grid = Grid(rows: 5, columns: 12)
        for row in 0..<5 {
            grid.moveCursor(row: row, column: 0)
            for _ in 0..<12 { grid.write(0x78) }
        }
        if partial { grid.setScrollRegion(top: 1, bottom: 3) }
        let top = partial ? 1 : 0, bottom = partial ? 3 : 4
        let address = grid.rowBufferAddress(top)
        let capacity = grid.line(top).cells.capacity
        grid.scrollUp(1)
        #expect(grid.line(bottom).cells.capacity == capacity)
        grid.moveCursor(row: bottom, column: 0)
        grid.write(0x79)
        #expect(address != nil)
        #expect(grid.rowBufferAddress(bottom) == address)
        let nextAddress = grid.rowBufferAddress(top)
        grid.scrollUp(1)
        grid.moveCursor(row: bottom, column: 0)
        grid.write(0x7A)
        #expect(grid.rowBufferAddress(bottom) == nextAddress)
    }

    @Test func snapshotRetainsCellsAndMetadata() {
        var grid = Grid(rows: 4, columns: 8)
        for row in 0..<4 {
            grid.moveCursor(row: row, column: 0)
            grid.write(UInt32(0x61 + row))
        }
        let snapshot = grid
        let expected = (0..<4).map { snapshot.line($0) }
        grid.scrollUp(2)
        grid.write(0x78)
        grid.setScrollRegion(top: 1, bottom: 3)
        grid.scrollDown(2)
        #expect((0..<4).map { snapshot.line($0) } == expected)
    }

    @Test func scrollbackMatchesTrimThenCopy() {
        var history = Scrollback(limit: 10)
        for blanks in [false, true] {
            for mark in [LineMark.none, .promptFailed, .outputStart] {
                var line = Line(wrapped: true)
                line.mark = mark
                line[0] = Cell.blank
                line[1] = Cell.blank
                line[1].scalar = 0x4E2D
                line[1].attributes.insert(.wide)
                line[2].attributes.insert(.wideSpacer)
                if blanks { line.fill(.blank, in: 3..<12) }
                var expected = line
                expected.trimTrailingBlanks()
                history.push(line)
                #expect(history[history.count - 1] == expected)
            }
        }
    }

    @Test func recycleClearsMarkAndWrap() {
        var line = Line(wrapped: true)
        line.mark = .promptFailed
        line[7].scalar = 0x78
        line.recycle()
        #expect(line.isEmpty && !line.wrapped && line.mark == .none)
    }
}
