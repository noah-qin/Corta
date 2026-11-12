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

/// A query with a scalar ASCII cannot produce skips the lines that are only
/// ASCII (#521). Whatever it skips must be what the `String` comparison would
/// not have matched anyway: `reference` runs that comparison on every logical
/// line, so the two must agree on every grid and query below.
@Suite("Search, non-ASCII queries")
struct SearchNonASCIIQueryTests {
    private static func terminal(_ lines: [String], rows: Int = 6, columns: Int = 20) -> Terminal {
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 100)
        terminal.feed(Array(lines.joined(separator: "\r\n").utf8))
        return terminal
    }

    /// Every match by the `String` comparison on every logical line, oldest
    /// first, no cap — the behaviour before the skip.
    private static func reference(_ query: String, in grid: Grid, caseSensitive: Bool) -> [SelectionRange] {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var found: [SelectionRange] = []
        for line in grid.reversedLogicalLines() {
            var searchStart = line.text.startIndex
            while let range = line.text.range(of: query, options: options, range: searchStart..<line.text.endIndex),
                !range.isEmpty
            {
                let startOffset = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                let endOffset = line.text.distance(from: line.text.startIndex, to: range.upperBound) - 1
                if let start = line.position(at: startOffset), let end = line.position(at: endOffset) {
                    found.append(
                        SelectionRange(
                            start: SelectionPoint(row: start.row, column: start.column),
                            end: SelectionPoint(row: end.row, column: end.column)))
                }
                searchStart = range.upperBound
            }
        }
        return found.sorted { ($0.start.row, $0.start.column) < ($1.start.row, $1.start.column) }
    }

    private func expectSame(
        _ query: String, _ lines: [String], columns: Int = 20, caseSensitive: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let terminal = Self.terminal(lines, columns: columns)
        let actual = Search.find(query, in: terminal.grid, caseSensitive: caseSensitive)
        let expected = Self.reference(query, in: terminal.grid, caseSensitive: caseSensitive)
        #expect(actual == expected, "query \(query)", sourceLocation: sourceLocation)
    }

    @Test("a CJK query over lines that mix ASCII, CJK and symbols")
    func cjkOverMixedLines() {
        let lines = ["plain ascii line", "状态: ok", "状态状态", "build ✓ done", "状 态", "日本語の状態", "ascii again"]
        expectSame("状态", lines)
        expectSame("状", lines)
        expectSame("状态", lines, caseSensitive: true)
        let terminal = Self.terminal(lines)
        #expect(Search.find("状态", in: terminal.grid).count == 3)
    }

    @Test("full-width and half-width forms stay distinct")
    func fullAndHalfWidth() {
        let lines = ["ABC abc", "ＡＢＣ ａｂｃ", "１２３ 123"]
        expectSame("ＡＢＣ", lines)
        expectSame("ａｂｃ", lines, caseSensitive: true)
        expectSame("１２３", lines)
        expectSame("ABC", lines)
    }

    @Test("a query that folds or decomposes to ASCII still reaches ASCII lines")
    func foldsToASCII() {
        #expect(!Search.queryNeedsNonASCII("\u{212A}", caseSensitive: false))  // Kelvin sign
        #expect(!Search.queryNeedsNonASCII("\u{212A}", caseSensitive: true))  // decomposes to K
        #expect(!Search.queryNeedsNonASCII("\u{037E}", caseSensitive: true))  // Greek question mark
        #expect(!Search.queryNeedsNonASCII("\u{FB00}", caseSensitive: false))  // ff ligature
        #expect(!Search.queryNeedsNonASCII("\u{1F}\u{301}", caseSensitive: false))  // a mark alone
        #expect(Search.queryNeedsNonASCII("状态", caseSensitive: false))
        #expect(Search.queryNeedsNonASCII("é", caseSensitive: true))
        #expect(Search.queryNeedsNonASCII("ＡＢ", caseSensitive: false))
        let lines = ["Kelvin kilo", "Keep k", "plain"]
        expectSame("\u{212A}", lines)
        expectSame("\u{212A}", lines, caseSensitive: true)
        expectSame("\u{FB00}", ["off", "stuff", "ﬀ"])
    }

    @Test("combining and format scalars keep the String path")
    func combiningAndFormat() {
        let lines = ["cafe\u{301} cafe", "caf\u{E9}", "a\u{200D}b ab", "e\u{301}"]
        expectSame("e\u{301}", lines)
        expectSame("\u{E9}", lines)
        expectSame("a\u{200D}b", lines)
        expectSame("caf\u{E9}", lines)
    }

    @Test("wide characters that wrap across rows")
    func wrappedWideCharacters() {
        let lines = ["abc状态状态状态状态状态状态状态状态xyz状态", "状态", String(repeating: "状", count: 30)]
        expectSame("状态", lines, columns: 7)
        expectSame("状态", lines, columns: 5)
        expectSame("态状", lines, columns: 8)
    }

    @Test("matches in scrollback and on the screen, with a cap")
    func scrollbackAndCap() {
        var lines: [String] = []
        for index in 0..<40 { lines.append(index % 5 == 0 ? "行 \(index) 状态" : "line \(index)") }
        let terminal = Self.terminal(lines, rows: 6)
        let all = Search.find("状态", in: terminal.grid)
        #expect(all == Self.reference("状态", in: terminal.grid, caseSensitive: false))
        #expect(all.count == 8)
        let capped = Search.find("状态", in: terminal.grid, maxMatches: 3)
        #expect(capped == Array(all.suffix(3)))
    }

    @Test("a stop that is already true scans nothing, and a stop mid-sweep ends the scan")
    func stopsAreHonoured() {
        let terminal = Self.terminal(["状态", "ascii", "状态"])
        #expect(Search.find("状态", in: terminal.grid, shouldStop: { true }).isEmpty)
        var polls = 0
        let partial = Search.find("状态", in: terminal.grid, shouldStop: { polls += 1; return polls > 1 })
        #expect(partial.count < 2)
    }
    @Test("history lines of CJK text are ruled out by their row index, and only by it when sure")
    func cjkHistoryLines() {
        var lines: [String] = []
        for index in 0..<60 {
            switch index % 6 {
            case 0: lines.append("终端性能测试 \(index) 日志状态正常")
            case 1: lines.append("请求已处理，耗时三毫秒 \(index)")
            case 2: lines.append("日本語の文章 \(index) 状 態")
            case 3: lines.append("plain ascii line \(index)")
            case 4: lines.append("状\u{301}态 \(index) 组合")
            default: lines.append(String(repeating: "状态说明", count: 12) + " \(index)")
            }
        }
        for query in ["状态", "状", "态", "日志", "测试", "说明状", "状态 x", "zzz状", "終端"] {
            expectSame(query, lines, columns: 20)
            expectSame(query, lines, columns: 7)
            expectSame(query, lines, columns: 20, caseSensitive: true)
        }
    }

    @Test("a compatibility ideograph in history is equivalent to its unified one, both ways")
    func compatibilityIdeographs() {
        var lines: [String] = []
        for index in 0..<40 { lines.append(index % 3 == 0 ? "豈 \(index) 更" : (index % 3 == 1 ? "豈 \(index)" : "其他 \(index)")) }
        for query in ["\u{F900}", "\u{8C48}", "\u{F900}\u{66F4}", "\u{8C48}\u{66F4}", "\u{66F4}", "\u{F901}"] {
            expectSame(query, lines, columns: 20)
        }
        // The line carries the unified form, the query the compatibility one.
        let unified = (0..<40).map { $0 % 2 == 0 ? "\u{8C48} \($0)" : "x \($0)" }
        expectSame("\u{F900}", unified, columns: 20)
        #expect(Search.isUnifiedIdeograph(0x8C48) && !Search.isUnifiedIdeograph(0xF900))
    }

}
