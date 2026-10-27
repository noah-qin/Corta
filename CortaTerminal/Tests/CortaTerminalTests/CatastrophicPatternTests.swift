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

/// The shape check that stops a pattern before it reaches a
/// backtracking engine, before the progress-callback guard is needed.
///
/// The measurements behind it: `(a+)+b` against a run of "a" took 0.016 s at
/// 18 characters, 0.52 s at 24 and 8.0 s at 28 on this machine — doubling
/// every two characters. There is no line length at which it is affordable,
/// which is why a length cap cannot be the guard and this is.
@Suite struct CatastrophicPatternTests {
    @Test("the classic exponential shapes are refused")
    func exponentialShapesRefused() {
        for pattern in [
            "(a+)+b", "(a*)*b", "(a|a)+b", "(a+|b)*c", "([a-z]+)+", "(\\d+)+",
            "(x(y+))+", "(a{2,})+",
        ] {
            #expect(Search.isCatastrophic(pattern), "\(pattern) should be refused")
        }
    }

    /// The patterns a person actually types must go through. A check that
    /// refuses ordinary searches is worse than the problem it solves.
    @Test("ordinary patterns are not refused")
    func ordinaryPatternsAllowed() {
        for pattern in [
            "error", "error \\d+", "^\\s*fatal", "TODO|FIXME", "[a-z]+@[a-z]+",
            "(abc)+", "(?:abc)+", "(a{2})+", "(a|b)", "foo.*bar$", "\\(a+\\)+",
            "warning: .*\\.swift:\\d+", "[(]a+[)]+",
        ] {
            #expect(!Search.isCatastrophic(pattern), "\(pattern) should be allowed")
        }
    }

    /// A refused pattern never reaches the engine, so the sweep returns at
    /// once rather than after however long ICU would have taken.
    @Test("a refused pattern finds nothing, immediately")
    func refusedPatternsDoNotRun() {
        var terminal = Terminal(rows: 4, columns: 200, scrollbackLimit: 10)
        terminal.feed(Array(String(repeating: "a", count: 120).utf8))
        let start = SuspendingClock.now
        let result = Search.findRegex("(a+)+b", in: terminal.grid)
        let elapsed = SuspendingClock.now - start
        #expect(result.matches.isEmpty)
        // 120 characters of that pattern would not finish in this universe.
        #expect(elapsed < .milliseconds(50))
    }

    /// A pattern that is merely slow — not exponential — stops on the time
    /// budget and says the count is a floor rather than a total.
    @Test("a sweep that runs long reports itself incomplete")
    func timeBudgetIsReported() {
        var terminal = Terminal(rows: 8, columns: 80, scrollbackLimit: 4000)
        for index in 0..<3000 { terminal.feed(Array("line \(index) of text\r\n".utf8)) }
        let result = Search.findRegex(
            "l.*e", in: terminal.grid, timeBudget: .milliseconds(1))
        #expect(result.timedOut)
        #expect(result.isIncomplete)
    }

    @Test("an ordinary sweep is complete")
    func ordinarySweepIsComplete() {
        var terminal = Terminal(rows: 8, columns: 80, scrollbackLimit: 100)
        terminal.feed(Array("hello world\r\n".utf8))
        let result = Search.findRegex("world", in: terminal.grid)
        #expect(result.matches.count == 1)
        #expect(!result.isIncomplete)
    }

    // MARK: - ASCII fast path parity (#115)

    /// The reference every parity case is held to: the same sweep computed
    /// only through the public `String` surface — `logicalLines()`,
    /// `range(of:)`, `position(at:)` — which is what `Search.find` did for
    /// every line before the byte path existed.
    private func referenceMatches(
        _ query: String, in grid: Grid, caseSensitive: Bool = false
    ) -> [SelectionRange] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var expected: [SelectionRange] = []
        for line in grid.logicalLines() {
            let text = line.text
            var from = text.startIndex
            while from < text.endIndex,
                let found = text.range(of: query, options: options, range: from..<text.endIndex)
            {
                let startOffset = text.distance(from: text.startIndex, to: found.lowerBound)
                let length = text.distance(from: found.lowerBound, to: found.upperBound)
                if let start = line.position(at: startOffset),
                    let end = line.position(at: startOffset + length - 1)
                {
                    expected.append(
                        SelectionRange(
                            start: SelectionPoint(row: start.row, column: start.column),
                            end: SelectionPoint(row: end.row, column: end.column)))
                }
                from = found.upperBound
            }
        }
        return expected
    }

    @Test("mixed Unicode ASCII path agrees with Foundation matching")
    func mixedUnicodeParity() {
        for text in [
            "fox ✓ fox", "fox 世界 FOX", "K k K", "ſ s S", "ﬀ ff", "e\u{301} e é", "foo\u{200D}bar foobar", "fox 🙂 fox",
        ] {
            var terminal = Terminal(rows: 5, columns: 9)
            terminal.feed(Array(text.utf8))
            for query in ["fox", "k", "s", "ff", "e", "foobar", " "] {
                for sensitive in [false, true] {
                    #expect(Search.find(query, in: terminal.grid, caseSensitive: sensitive)
                        == referenceMatches(query, in: terminal.grid, caseSensitive: sensitive))
                }
            }
        }
    }

    @Test("the byte path and the String path agree on plain ASCII")
    func parityOnASCII() {
        var terminal = Terminal(rows: 6, columns: 24)
        terminal.feed(Array("the quick brown fox\r\njumped over the fox\r\nFOX and fox\r\n".utf8))
        for caseSensitive in [false, true] {
            #expect(
                Search.find("fox", in: terminal.grid, caseSensitive: caseSensitive)
                    == referenceMatches("fox", in: terminal.grid, caseSensitive: caseSensitive))
        }
    }

    /// The line forces the fallback, the query does not — so one sweep runs
    /// both paths and the result has to read as if only one had.
    @Test("a non-ASCII line inside an ASCII search still matches correctly")
    func parityWithOneNonASCIILine() {
        var terminal = Terminal(rows: 8, columns: 32)
        terminal.feed(Array("fox one\r\n狐狸 fox two\r\nfox three\r\n".utf8))
        #expect(Search.find("fox", in: terminal.grid) == referenceMatches("fox", in: terminal.grid))
        #expect(Search.find("fox", in: terminal.grid).count == 3)
    }

    @Test("a non-ASCII query takes the String path and still matches")
    func parityWithNonASCIIQuery() {
        var terminal = Terminal(rows: 6, columns: 32)
        terminal.feed(Array("狐狸 one\r\ntwo 狐狸\r\n".utf8))
        #expect(
            Search.find("狐狸", in: terminal.grid) == referenceMatches("狐狸", in: terminal.grid))
        #expect(Search.find("狐狸", in: terminal.grid).count == 2)
    }

    /// A wide character occupies two columns and contributes one character,
    /// so the byte path's column mapping has to skip the spacer exactly as
    /// the `String` path does.
    @Test("columns after a wide character are reported from the grid, not the byte offset")
    func parityAfterAWideCharacter() {
        var terminal = Terminal(rows: 5, columns: 24)
        terminal.feed(Array("狐 fox".utf8))
        #expect(Search.find("fox", in: terminal.grid) == referenceMatches("fox", in: terminal.grid))
    }

    @Test("a match straddling a soft wrap agrees with the String path")
    func parityAcrossASoftWrap() {
        var terminal = Terminal(rows: 6, columns: 8)
        terminal.feed(Array("aaaafoxbbbb".utf8))
        #expect(Search.find("fox", in: terminal.grid) == referenceMatches("fox", in: terminal.grid))
    }

    /// `byte | 0x20` folds `[` to `{`; the table does not. A search for a
    /// bracket must not find a brace.
    @Test("ASCII folding does not fold punctuation into letters")
    func foldingDoesNotTouchPunctuation() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("{braced} [square]".utf8))
        #expect(Search.find("[", in: terminal.grid).count == 1)
        #expect(Search.find("[", in: terminal.grid) == referenceMatches("[", in: terminal.grid))
        #expect(Search.find("@", in: terminal.grid).isEmpty)
    }

    /// Trailing blanks are trimmed per row by both paths, so neither finds a
    /// query that only exists in the padding.
    @Test("trailing blanks are trimmed identically by both paths")
    func parityOnTrailingBlanks() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("fox".utf8))
        #expect(Search.find("fox ", in: terminal.grid).isEmpty)
        #expect(Search.find("fox ", in: terminal.grid) == referenceMatches("fox ", in: terminal.grid))
    }

    @Test("a capped ASCII sweep keeps the newest matches, as the String path did")
    func parityUnderTheMatchCap() {
        var terminal = Terminal(rows: 10, columns: 20)
        for index in 0..<10 {
            terminal.feed(Array("fox \(index)\r\n".utf8))
        }
        let capped = Search.find("fox", in: terminal.grid, maxMatches: 3)
        #expect(capped.count == 3)
        #expect(Array(referenceMatches("fox", in: terminal.grid).suffix(3)) == capped)
    }
}
