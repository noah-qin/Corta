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

/// A run of CJK ideographs is written as pairs in one call (#536). One byte
/// at a time can never form a run, so it is the reference: any stream fed
/// whole or cut anywhere must leave the same cells, cursor and pending wrap.
@Suite("CJK runs")
struct CJKRunTests {
    @Test("every ideograph of the block is width 2 and plain, which the run assumes")
    func blockAssumptions() {
        for value in UInt32(0x4E00)...UInt32(0x9FFF) {
            let scalar = Unicode.Scalar(value)!
            #expect(displayWidth(of: scalar) == 2, "U+\(String(value, radix: 16, uppercase: true))")
            #expect(!ConcealingScalars.contains(value))
            #expect(!Grid.isAmbiguous(value))
            #expect(!(0x1F1E6...0x1F1FF).contains(value))
            #expect(scalar.properties.generalCategory == .otherLetter)
        }
    }

    private struct Snapshot: Equatable {
        var lines: [Line]
        var cursor: Cursor
        var pendingWrap: Bool
    }

    private func snapshot(_ bytes: [UInt8], chunks: [Range<Int>], rows: Int, columns: Int) -> Snapshot {
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 4)
        for chunk in chunks { terminal.feed(bytes[chunk]) }
        let grid = terminal.grid
        return Snapshot(
            lines: (0..<rows).map { grid.documentLine($0) }, cursor: grid.cursor, pendingWrap: grid.pendingWrap)
    }

    private func expectEquivalent(
        _ bytes: [UInt8], rows: Int = 4, columns: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let reference = snapshot(bytes, chunks: bytes.indices.map { $0..<($0 + 1) }, rows: rows, columns: columns)
        #expect(
            snapshot(bytes, chunks: [0..<bytes.count], rows: rows, columns: columns) == reference,
            "columns \(columns) bytes \(bytes)", sourceLocation: sourceLocation)
        for cut in stride(from: 1, to: bytes.count, by: 1) {
            #expect(
                snapshot(bytes, chunks: [0..<cut, cut..<bytes.count], rows: rows, columns: columns) == reference,
                "columns \(columns) cut \(cut) bytes \(bytes)", sourceLocation: sourceLocation)
        }
    }

    @Test("runs at every column offset, on every width, with wraps")
    func runsAtEveryOffset() {
        for columns in [1, 2, 3, 4, 5, 6, 7, 8, 11] {
            for lead in 0...columns + 1 {
                for length in [1, 2, 3, 4, 5, 9] {
                    let bytes =
                        Array(String(repeating: "a", count: lead).utf8)
                        + Array(String(repeating: "中", count: length).utf8) + Array("z".utf8)
                    expectEquivalent(bytes, columns: columns)
                }
            }
        }
    }

    @Test("over existing wide pairs, narrow cells and spacers")
    func overExistingContent() {
        for columns in [5, 6, 7, 8] {
            for start in 0..<columns {
                let base = Array("一二三四五六\r\n".utf8) + Array("ab一cd二ef\r\n".utf8)
                let move = Array("\u{1B}[1;\(start + 1)H".utf8)
                for length in [2, 3, 4] {
                    expectEquivalent(
                        base + move + Array(String(repeating: "中", count: length).utf8), columns: columns)
                    expectEquivalent(
                        base + Array("\u{1B}[2;\(start + 1)H".utf8) + Array(String(repeating: "文", count: length).utf8)
                            + Array("\u{1B}[1;1H你好".utf8),
                        columns: columns)
                }
            }
        }
    }

    @Test("insert mode, autowrap off, colours, ZWJ before a run and escapes inside one")
    func modesAndInterruptions() {
        let run = Array("中文测试汉字".utf8)
        let cases: [[UInt8]] = [
            Array("\u{1B}[4habc".utf8) + run, Array("\u{1B}[4h".utf8) + run + run,
            Array("\u{1B}[?7l".utf8) + run + run, Array("\u{1B}[?7la".utf8) + run,
            Array("\u{1B}[31;44m".utf8) + run + Array("\u{1B}[0m".utf8) + run,
            Array("👩\u{200D}".utf8) + run, Array("👨\u{200D}👩".utf8) + run + run,
            Array("中\u{200D}".utf8) + run, Array("中文".utf8) + [0xE6, 0x96] + Array("\u{1B}[1m测试".utf8),
            Array("中文".utf8) + [0xE6, 0x96, 0x1B, 0x5B, 0x41] + run,
            Array("中文测\u{301}试汉字".utf8), Array("中文\u{FE0F}测试".utf8),
            // Outside the block: a neighbour, extension A, a radical, Hangul, kana.
            Array("\u{4DFF}\u{4E00}\u{9FFF}\u{A000}\u{3400}\u{2E80}한글あア".utf8),
            // Malformed three-byte lookalikes among ideographs.
            [0xE4, 0xB8, 0xAD, 0xE4, 0xB8, 0x41, 0xE4, 0xB8, 0xAD, 0xE4, 0xB8, 0xAD],
            [0xE4, 0xB7, 0xBF, 0xE4, 0xB8, 0x80, 0xE4, 0xB8, 0x80],  // U+4DFF then two ideographs
            [0xE9, 0xBF, 0xBF, 0xE9, 0xC0, 0x80, 0xE9, 0xBF, 0xBF],
        ]
        for bytes in cases {
            for columns in [1, 2, 3, 5, 6, 8, 9] { expectEquivalent(bytes, columns: columns) }
        }
    }

    @Test("a seeded random mix of ideographs, ASCII, wide and escapes")
    func randomMix() {
        var seed: UInt64 = 0x536
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        let pieces: [[UInt8]] = [
            Array("中".utf8), Array("文".utf8), Array("a".utf8), Array("é".utf8), Array("😀".utf8),
            Array("\r\n".utf8), Array("\r".utf8), Array("\u{1B}[3D".utf8), Array("\u{1B}[2C".utf8),
            Array("\u{1B}[4h".utf8), Array("\u{1B}[4l".utf8), Array("\u{1B}[?7l".utf8), Array("\u{1B}[?7h".utf8),
            Array("\u{1B}[1;32m".utf8), Array("\u{1B}[0m".utf8), Array("\u{200D}".utf8), Array("\u{301}".utf8),
            Array("一二三".utf8), Array("你好世界".utf8), [0xE6, 0x96], [0xE4],
        ]
        for _ in 0..<600 {
            var bytes: [UInt8] = []
            for _ in 0..<(3 + Int(next() % 14)) { bytes += pieces[Int(next() % UInt64(pieces.count))] }
            expectEquivalent(bytes, columns: 1 + Int(next() % 11))
        }
    }
}
