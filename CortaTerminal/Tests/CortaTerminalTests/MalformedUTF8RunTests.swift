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

/// A run of malformed bytes is written as a run of U+FFFD cells. The byte-at-
/// a-time path (`Terminal.feed` of a plain `Sequence`) takes no fast path at
/// all, so it is the reference: the grid must come out the same in every
/// field of every cell, not only in what the golden dump shows.
@Suite("Malformed UTF-8 runs")
struct MalformedUTF8RunTests {
    private struct Screen {
        var rows = 4
        var columns = 10
        var ambiguousIsWide = false
    }

    private func exactState(_ terminal: Terminal) -> String {
        let grid = terminal.grid
        var text = "cursor \(grid.cursor.row),\(grid.cursor.column) wrap \(grid.pendingWrap)\n"
        for index in 0..<grid.scrollback.count {
            text += line(grid.scrollback[index], "s\(index)", terminal)
        }
        for row in 0..<grid.rows { text += line(grid.lines[row], "\(row)", terminal) }
        return text
    }

    private func line(_ line: Line, _ label: String, _ terminal: Terminal) -> String {
        var text = "\(label) \(line.wrapped ? "W" : "-") n\(line.count):"
        for column in 0..<line.count {
            let cell = line[column]
            let cluster = terminal.grid.graphemes.scalars(for: cell.grapheme) ?? []
            text += " \(String(cell.scalar, radix: 16))/\(cell.attributes.rawValue)/h\(cell.hyperlink.rawValue)"
            text += "/\(cell.foreground.rawValue)/\(cell.background.rawValue)/\(cluster)"
        }
        return text + "\n"
    }

    /// Fed whole (the fast path) and byte by byte (the reference), in chunks
    /// that split runs at arbitrary points.
    private func expectSame(_ bytes: [UInt8], _ screen: Screen = Screen(), chunk: Int = 7,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        var fast = Terminal(rows: screen.rows, columns: screen.columns, scrollbackLimit: 16)
        var reference = Terminal(rows: screen.rows, columns: screen.columns, scrollbackLimit: 16)
        fast.grid.ambiguousIsWide = screen.ambiguousIsWide
        reference.grid.ambiguousIsWide = screen.ambiguousIsWide
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunk)
            fast.feed(bytes[offset..<end])
            reference.feed(AnySequence(bytes[offset..<end]))
            offset = end
        }
        #expect(exactState(fast) == exactState(reference), sourceLocation: sourceLocation)
    }

    private static func bytes(_ text: String, _ malformed: [UInt8] = []) -> [UInt8] { Array(text.utf8) + malformed }

    private static let run = [UInt8](repeating: 0xFF, count: 25) + [0x80, 0xBF, 0xC0, 0xC1, 0xF5, 0xFE, 0x9B]

    @Test("a run wraps, scrolls and keeps the pen and link as the reference does")
    func plainRunMatches() {
        expectSame(Self.bytes("ab\u{1B}[31;44m\u{1B}]8;;https://a.test\u{1B}\\", Self.run) + Self.run)
        expectSame(Self.run, chunk: 1)
        expectSame(Self.run + Self.run + Self.run, chunk: 64)
    }

    /// The first U+FFFD continues a ZWJ cluster; the rest are cells of their own.
    @Test("after a ZWJ, the first joins the cluster and the rest do not")
    func afterZWJ() {
        expectSame(Self.bytes("👩\u{200D}", Self.run), chunk: 64)
        expectSame(Self.bytes("x\u{200D}", Self.run), chunk: 3)
    }

    @Test("after a lone regional indicator")
    func afterRegionalIndicator() {
        expectSame(Self.bytes("\u{1F1E6}", Self.run), chunk: 64)
    }

    @Test("over wide pairs and clusters already on the row")
    func overWidePairs() {
        expectSame(Self.bytes("世界世界e\u{301}\r", Self.run), chunk: 64)
        expectSame(Self.bytes("a世界世界\r\u{1B}[2C", [0xFF, 0xFF, 0xFF]), chunk: 64)
    }

    @Test("autowrap off, insert mode and wide U+FFFD write each one")
    func modesThatWriteEachOne() {
        expectSame(Self.bytes("\u{1B}[?7l12345678", Self.run), chunk: 64)
        expectSame(Self.bytes("a\u{200D}\u{1B}[?7l12345678", Self.run), chunk: 64)
        expectSame(Self.bytes("abcdef\r\u{1B}[4h", Self.run), chunk: 64)
        expectSame(Self.bytes("abcdef\r\u{1B}[4h", [0xFF, 0xFF, 0xFF]), chunk: 64)
        expectSame(Self.run + Self.run, Screen(ambiguousIsWide: true), chunk: 64)
    }

    @Test("a one-column screen")
    func oneColumn() {
        expectSame(Self.run, Screen(rows: 3, columns: 1), chunk: 64)
    }

    /// Ends of runs: a truncated sequence, a valid scalar, controls and ESC.
    @Test("runs meet sequences, controls and escapes")
    func boundaries() {
        expectSame([0xE4, 0xB8] + Self.run + [0xE4, 0xB8, 0xAD, 0xFF, 0x0D, 0xFF, 0x1B, 0x5B, 0x41, 0xFF], chunk: 2)
        expectSame([0xF0, 0x9F] + Self.run + [0xC3, 0xA9, 0xFF], chunk: 64)
    }

    /// Every corpus input, and mutations of it, cell for cell.
    @Test("the fuzz corpus comes out the same cell for cell")
    func fuzzCorpus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fuzz/corpus")
        let corpus = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }.map { Array(try Data(contentsOf: $0)) }
        #expect(!corpus.isEmpty)
        var seed: UInt64 = 0x4D5
        func random() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed
        }
        for input in corpus {
            expectSame(input, Screen(rows: 6, columns: 20), chunk: 33)
            var mutated = input
            for _ in 0..<max(1, mutated.count / 6) where !mutated.isEmpty {
                // Biased to the bytes this path takes.
                let byte = random() % 2 == 0 ? UInt8(0x80 + random() % 0x42) : UInt8(0xF5 + random() % 11)
                mutated[Int(random() % UInt64(mutated.count))] = byte
            }
            expectSame(mutated, Screen(rows: 6, columns: 20), chunk: 17)
        }
    }
}
