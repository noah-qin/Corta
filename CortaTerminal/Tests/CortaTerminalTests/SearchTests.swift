import Testing

@testable import CortaTerminal

/// M4.4 — scrollback search: case-insensitive by default, matches over
/// logical lines so a wrap boundary doesn't split a match.
@Suite("Search")
struct SearchTests {
    @Test("finds a plain match on one row")
    func plainMatch() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello world".utf8))
        let matches = Search.find("world", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start == SelectionPoint(row: 0, column: 6))
        #expect(matches[0].end == SelectionPoint(row: 0, column: 10))
    }

    @Test("is case-insensitive by default")
    func caseInsensitiveByDefault() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("Hello World".utf8))
        #expect(Search.find("world", in: terminal.grid).count == 1)
        #expect(Search.find("WORLD", in: terminal.grid).count == 1)
    }

    @Test("case-sensitive search excludes a differently-cased match")
    func caseSensitiveOptIn() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("Hello World".utf8))
        #expect(Search.find("world", in: terminal.grid, caseSensitive: true).isEmpty)
        #expect(Search.find("World", in: terminal.grid, caseSensitive: true).count == 1)
    }

    @Test("a match spanning a soft wrap is found whole")
    func matchSpansSoftWrap() {
        var terminal = Terminal(rows: 5, columns: 8)
        // "abcdefgh" wraps into "abcdefgh" over two rows at 8 columns... use
        // a query that straddles the wrap boundary.
        terminal.feed(Array("1234567890".utf8))  // wraps at column 8: "12345678"/"90"
        let matches = Search.find("7890", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start == SelectionPoint(row: 0, column: 6))
        #expect(matches[0].end == SelectionPoint(row: 1, column: 1))
    }

    @Test("finds multiple matches on the same logical line")
    func multipleMatchesOnOneLine() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("cat and cat and cat".utf8))
        let matches = Search.find("cat", in: terminal.grid)
        #expect(matches.count == 3)
    }

    @Test("finds a match already in scrollback")
    func matchInScrollback() {
        var terminal = Terminal(rows: 2, columns: 20, scrollbackLimit: 10)
        terminal.feed(Array("findme\r\nsecond\r\nthird".utf8))
        #expect(terminal.grid.scrollback.count >= 1)
        let matches = Search.find("findme", in: terminal.grid)
        #expect(matches.count == 1)
        #expect(matches[0].start.row < 0)
    }

    @Test("an empty query matches nothing")
    func emptyQueryMatchesNothing() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello".utf8))
        #expect(Search.find("", in: terminal.grid).isEmpty)
    }

    @Test("no match returns an empty array without trapping")
    func noMatch() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("hello".utf8))
        #expect(Search.find("goodbye", in: terminal.grid).isEmpty)
    }

    // P04/P08 — the cap, cooperative cancellation, newest-first collection
    // and the bounded long-line scan.

    @Test("matches report oldest first, left to right within a line")
    func resultOrder() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("aa bb aa\r\ncc aa".utf8))
        let matches = Search.find("aa", in: terminal.grid)
        #expect(
            matches.map(\.start) == [
                SelectionPoint(row: 0, column: 0),
                SelectionPoint(row: 0, column: 6),
                SelectionPoint(row: 1, column: 3),
            ])
    }

    @Test("the match cap keeps the newest matches")
    func capKeepsNewestMatches() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("aa first\r\naa second\r\naa third".utf8))
        let matches = Search.find("aa", in: terminal.grid, maxMatches: 2)
        #expect(matches.count == 2)
        // The oldest of the three is the one dropped, and the kept pair
        // still reports oldest first.
        #expect(matches[0].start.row == 1)
        #expect(matches[1].start.row == 2)
    }

    @Test("a stop that is already true scans nothing")
    func cancellationBeforeTheFirstLine() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("aa\r\naa\r\naa".utf8))
        #expect(Search.find("aa", in: terminal.grid, shouldStop: { true }).isEmpty)
    }

    @Test("a stop mid-sweep ends the scan cooperatively")
    func cancellationMidSweep() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.feed(Array("aa\r\naa\r\naa".utf8))
        var calls = 0
        let matches = Search.find(
            "aa", in: terminal.grid,
            shouldStop: {
                calls += 1
                return calls > 2
            })
        // The sweep collects newest first, so the newest line's match was
        // found before the stop landed; the two older lines contribute
        // nothing — the oldest was never scanned at all.
        #expect(matches.map(\.start) == [SelectionPoint(row: 2, column: 0)])
    }

    @Test("a 1 MB match-dense logical line is bounded by the cap")
    func megabyteLongLineIsBounded() {
        var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 20_000)
        terminal.feed([UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000))
        let matches = Search.find("aa", in: terminal.grid, maxMatches: 100)
        #expect(matches.count == 100)
        // 1_000_000 characters over 120 columns: the chain's last row is
        // screen row 49 (8_334 rows, 50 on screen) holding the final 40
        // columns. The cap keeps the newest matches, so the last one ends
        // on the line's final character.
        #expect(matches.last?.end == SelectionPoint(row: 49, column: 39))
    }

    @Test("reversed logical-line iteration visits the same lines, backwards")
    func reversedIteration() {
        var terminal = Terminal(rows: 5, columns: 8, scrollbackLimit: 10)
        terminal.feed(Array("aaaabbbbcccc\r\ndd\r\nee".utf8))
        // The trailing "" is the empty row under the cursor — both
        // directions visit it.
        let forward = terminal.grid.logicalLines().map(\.text)
        #expect(forward == ["aaaabbbbcccc", "dd", "ee", ""])
        #expect(terminal.grid.reversedLogicalLines().map(\.text) == forward.reversed())
    }
}

/// U16 — regular-expression search, with the budget and the cancellation the
/// substring path already had, plus the per-line bound that makes the
/// cancellation reachable at all.
@Suite struct RegexSearchTests {
    private static func terminal(_ lines: [String], columns: Int = 40) -> Terminal {
        var terminal = Terminal(rows: 8, columns: columns, scrollbackLimit: 500)
        for line in lines { terminal.feed(Array("\(line)\r\n".utf8)) }
        return terminal
    }

    @Test("a pattern matches what a pattern should")
    func basicMatching() {
        let terminal = Self.terminal(["error 404", "error 500", "ok 200"])
        let result = Search.findRegex("error \\d+", in: terminal.grid)
        #expect(result.matches.count == 2)
        #expect(result.skippedLongLines == 0)
    }

    @Test("case sensitivity applies to patterns too")
    func caseSensitivity() {
        let terminal = Self.terminal(["Error", "error", "ERROR"])
        #expect(Search.findRegex("error", in: terminal.grid, caseSensitive: false).matches.count == 3)
        #expect(Search.findRegex("error", in: terminal.grid, caseSensitive: true).matches.count == 1)
    }

    /// Anchors work because matching runs per logical line, which is the same
    /// unit the substring path uses — a soft wrap is not a line boundary.
    @Test("anchors bind to logical lines")
    func anchors() {
        let terminal = Self.terminal(["alpha beta", "beta alpha"])
        #expect(Search.findRegex("^alpha", in: terminal.grid).matches.count == 1)
        #expect(Search.findRegex("alpha$", in: terminal.grid).matches.count == 1)
    }

    /// A half-typed pattern is the normal state of a pattern being typed.
    /// "Invalid" and "no matches" are different things and the caller has to
    /// be able to tell them apart.
    @Test("an invalid pattern is reported, not silently empty")
    func invalidPattern() {
        #expect(!Search.isValidRegex("(unclosed", caseSensitive: false))
        #expect(!Search.isValidRegex("", caseSensitive: false))
        #expect(Search.isValidRegex("a+b", caseSensitive: false))
        let terminal = Self.terminal(["anything"])
        #expect(Search.findRegex("(unclosed", in: terminal.grid).matches.isEmpty)
    }

    /// A pattern that matches nothing at every position must not spin.
    @Test("zero-length matches do not loop")
    func zeroLengthMatches() {
        let terminal = Self.terminal(["abc"])
        #expect(Search.findRegex("x*", in: terminal.grid).matches.isEmpty)
        #expect(Search.findRegex("^", in: terminal.grid).matches.isEmpty)
    }

    @Test("the match cap bounds the result and keeps the newest")
    func matchCap() {
        let terminal = Self.terminal((0..<50).map { "hit \($0)" })
        let capped = Search.findRegex("hit", in: terminal.grid, maxMatches: 10)
        #expect(capped.matches.count == 10)
        // Newest kept: the last line searched is the most recent one.
        let all = Search.findRegex("hit", in: terminal.grid)
        #expect(capped.matches.last == all.matches.last)
    }

    @Test("cancellation stops the sweep")
    func cancellation() {
        let terminal = Self.terminal((0..<200).map { "hit \($0)" })
        var polls = 0
        let result = Search.findRegex(
            "hit", in: terminal.grid,
            shouldStop: {
                polls += 1
                return polls > 3
            })
        #expect(result.matches.count < 200)
    }

    /// The bound exists because `NSRegularExpression` backtracks and cannot
    /// be given a timeout: on one enormous line the between-lines
    /// cancellation check is never reached. A skipped line is *counted* so
    /// the caller can say the search was incomplete rather than finding
    /// nothing and saying nothing.
    @Test("a line past the length bound is skipped and counted")
    func longLinesAreSkipped() {
        var terminal = Terminal(rows: 4, columns: 200, scrollbackLimit: 2000)
        terminal.feed(Array(String(repeating: "a", count: Search.regexLineLimit + 100).utf8))
        terminal.feed(Array("\r\nshort needle\r\n".utf8))
        let result = Search.findRegex("needle", in: terminal.grid)
        #expect(result.matches.count == 1)
        #expect(result.skippedLongLines == 1)
    }
}

/// U16 — the shape check that stops a pattern before it reaches a
/// backtracking engine that cannot be interrupted.
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
        let start = ContinuousClock.now
        let result = Search.findRegex("(a+)+b", in: terminal.grid)
        let elapsed = ContinuousClock.now - start
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
