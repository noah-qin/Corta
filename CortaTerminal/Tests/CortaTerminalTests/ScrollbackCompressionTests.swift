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

@Suite struct ScrollbackCompressionTests {
    private func history() -> Scrollback {
        var history = Scrollback(limit: 4096)
        for row in 0..<4096 {
            var line = Line(wrapped: row % 3 == 0)
            if row % 17 != 0 {
                for column in 0..<120 {
                    line[column] = Cell(scalar: column % 4 == 0 ? 0x4E2D : 0x61,
                        foreground: .default, background: .default,
                        attributes: column % 4 == 0 ? .wide : [.bold, .underline],
                        grapheme: GraphemeID(rawValue: UInt16(row % 9)),
                        hyperlink: HyperlinkID(rawValue: UInt16(row % 7)))
                }
            }
            history.push(line)
        }
        return history
    }
    @Test func variedAttributesAndEmptyRowsRoundTrip() {
        var history = Scrollback(limit: 2048)
        var seed: UInt64 = 288
        func random() -> UInt16 {
            seed = seed &* 6364136223846793005 &+ 1
            return UInt16(truncatingIfNeeded: seed >> 32)
        }
        for row in 0..<2048 {
            var line = Line(wrapped: row % 2 == 0)
            for column in 0..<(row % 17 == 0 ? 0 : 120) {
                line[column] = Cell(scalar: column % 3 == 0 ? 0x4E2D : 0x61,
                    foreground: .indexed(UInt8(row % 256)), background: .rgb(12, 34, UInt8(row % 256)),
                    attributes: .init(rawValue: random()), grapheme: .init(rawValue: UInt16(row % 9)),
                    hyperlink: .init(rawValue: UInt16(row % 7)))
            }
            history.push(line)
        }
        let original = history.lines
        history.compressColdBatches()
        #expect(history.compressedBatchCount > 0)
        #expect(history.lines == original)
    }
    @Test func searchNeverCachesAMutableTail() {
        var terminal = Terminal(rows: 2, columns: 120)
        terminal.feed(Array("first\r\nsecond\r\nthird\r\n".utf8))
        #expect(!Search.find("first", in: terminal.grid).isEmpty)
        terminal.feed(Array("new tail content\r\nlast\r\n".utf8))
        #expect(!Search.find("new tail", in: terminal.grid).isEmpty)
        terminal.grid.clearScrollback()
        #expect(Search.find("first", in: terminal.grid).isEmpty)
    }

    @Test func parkedMainHistoryIsCompressedWithoutMutatingSnapshots() {
        var terminal = Terminal(rows: 8, columns: 120, scrollbackLimit: 4096)
        for _ in 0..<4096 { terminal.feed(Array("parked history contents\r\n".utf8)) }
        let snapshot = terminal.grid
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.compressColdScrollback()
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.grid.scrollback.compressedBatchCount > 0)
        #expect(snapshot.scrollback.compressedBatchCount == 0)
        #expect(terminal.grid.dump(options: .init(includeScrollback: true)) == snapshot.dump(options: .init(includeScrollback: true)))
    }

    @Test func roundTripAndSnapshot() throws {
        var history = history()
        let snapshot = history
        history.compressColdBatches()
        #expect(history.compressedBatchCount > 0)
        #expect(snapshot.compressedBatchCount == 0)
        for index in 0..<history.count { #expect(history[index] == snapshot[index]) }
        history.setMark(.promptFailed, at: 3)
        #expect(history[3].mark == .promptFailed)
        #expect(snapshot[3].mark == .none)
        #expect(history.liveHyperlinkIDs() == snapshot.liveHyperlinkIDs())
        #expect(history.liveGraphemeIDs() == snapshot.liveGraphemeIDs())
        // Check partially evicted oldest batches against their live cells.
        for _ in 0..<19 { history.push(Line()) }
        let links = Set(history.lines.flatMap { $0.cells }.map(\.hyperlink).filter { !$0.isNone })
        let graphemes = Set(history.lines.flatMap { $0.cells }.map(\.grapheme).filter { !$0.isNone })
        #expect(history.liveHyperlinkIDs() == links)
        #expect(history.liveGraphemeIDs() == graphemes)
    }
    @Test func clearRejectsOldWorkAndDropsDecodedContent() throws {
        var history = history()
        let work = try #require(history.nextCompressionWork())
        history.compressColdBatches()
        _ = history[0]
        history.removeAll()
        let installed = history.installCompression(work.compress())
        #expect(!installed)
        #expect(history.compressedBatchCount == 0)
        #expect(history[0].isEmpty)
        #expect(history.liveHyperlinkIDs().isEmpty)
        #expect(history.liveGraphemeIDs().isEmpty)
    }
    @Test func searchAndReflowRemainEquivalent() {
        var terminal = Terminal(rows: 8, columns: 120, scrollbackLimit: 4096)
        for row in 0..<4096 { terminal.feed(Array("row \(row) Kelvin K 中文 🚀 needle\r\n".utf8)) }
        var compressed = terminal.grid
        compressed.scrollback.compressColdBatches()
        for query in ["needle", "k", "中文", "row 2", "[", "🚀"] {
            #expect(Search.find(query, in: compressed) == Search.find(query, in: terminal.grid))
        }
        var plain = terminal.grid
        compressed.resize(rows: 8, columns: 80)
        plain.resize(rows: 8, columns: 80)
        #expect(compressed.dump(options: .init(includeScrollback: true)) == plain.dump(options: .init(includeScrollback: true)))
    }
    @Test func concurrentSnapshotsReadEvictedAndClearedCaches() async {
        var terminal = Terminal(rows: 4, columns: 80, scrollbackLimit: 2048)
        for row in 0..<2052 { terminal.feed(Array("row \(row) needle\r\n".utf8)) }
        let plain = terminal.grid
        terminal.compressColdScrollback()
        let snapshot = terminal.grid
        terminal.grid.clearScrollback()
        #expect(terminal.grid.scrollback.isEmpty)
        await withTaskGroup(of: Bool.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for step in 0..<128 {
                        let row = (worker * 17 + step * 37) % snapshot.scrollback.count
                        if snapshot.scrollback[row] != plain.scrollback[row] { return false }
                    }
                    return Search.find("needle", in: snapshot) == Search.find("needle", in: plain)
                }
            }
            for await equal in group { #expect(equal) }
        }
    }

    @Test func compressionResultsMayArriveOutOfOrder() throws {
        var current = history(), snapshot = current
        let first = try #require(snapshot.nextCompressionWork())
        let installedFirst = snapshot.installCompression(first.compress())
        #expect(installedFirst)
        let second = try #require(snapshot.nextCompressionWork())
        let installedSecond = current.installCompression(second.compress())
        #expect(installedSecond)
        current.compressColdBatches()
        #expect(current.compressedBatchCount == current.batchCount - 5)
        current.removeAll()
        for _ in 0..<2048 { current.push(Line()) }
        #expect(current.nextCompressionWork() != nil)
        current.compressColdBatches()
        #expect(current.nextCompressionWork() == nil)
    }

}
