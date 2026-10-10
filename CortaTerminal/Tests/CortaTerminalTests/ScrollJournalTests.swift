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

struct ScrollJournalTests {
    @Test func revisionsMoveAndVacatedRowsAreStamped() {
        var lines = ScreenLines(repeating: Line(), count: 6)
        for row in 0..<6 { lines[row][0].scalar = UInt32(0x61 + row) }
        // Exercise a region that crosses the circular buffer's physical head.
        lines.rotateUp(2)
        let revisions = (0..<6).map { lines.revision(at: $0) }
        lines.rotate(top: 1, bottom: 4, by: -2)
        #expect(lines.revision(at: 3) == revisions[1])
        #expect(lines.revision(at: 4) == revisions[2])
        #expect(lines.revision(at: 1) != revisions[1])
        #expect(lines.revision(at: 0) == revisions[0])
        #expect(lines.revision(at: 5) == revisions[5])
        #expect(lines[1].isEmpty && lines[2].isEmpty)
    }

    @Test func journalOrdersEventsAndRejectsOverflow() {
        var lines = ScreenLines(repeating: Line(), count: 6)
        lines.rotateUp(1)
        lines.rotate(top: 1, bottom: 4, by: -2)
        #expect(lines.scrollEventsTotal == 2)
        #expect(lines.scrollEvent(at: 0) == ScrollEvent(top: 0, bottom: 5, delta: 1))
        #expect(lines.scrollEvent(at: 1) == ScrollEvent(top: 1, bottom: 4, delta: -2))
        for _ in 0..<64 { lines.rotateUp(1) }
        #expect(lines.scrollEvent(at: 1) == nil)
        #expect(lines.scrollEvent(at: 2) != nil)
        #expect(lines.scrollEvent(at: 65) != nil)
        #expect(lines.scrollEvent(at: 66) == nil)
        let fresh = ScreenLines(repeating: Line(), count: 6)
        #expect(fresh.generation != lines.generation)
        #expect(fresh.scrollEventsTotal == 0 && fresh.scrollEvent(at: 0) == nil)
    }

    @Test func explicitSwapStampsBothRows() {
        var lines = ScreenLines(repeating: Line(), count: 4)
        lines[0][0].scalar = 0x61
        lines[1][0].scalar = 0x62
        let revisions = (0..<4).map { lines.revision(at: $0) }
        lines.swapAt(0, 1)
        #expect(lines[0][0].scalar == 0x62 && lines[1][0].scalar == 0x61)
        #expect(lines.revision(at: 0) != revisions[0] && lines.revision(at: 1) != revisions[1])
        #expect(lines.revision(at: 2) == revisions[2])
    }
}
