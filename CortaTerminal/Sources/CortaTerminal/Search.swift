import Foundation

/// Scrollback search (M4.4).
///
/// Matching is over logical lines (`Grid+Text.swift`), not rows, so a match
/// spanning a soft wrap is found whole. Case-insensitive by default. Reuses
/// `SelectionRange`/`SelectionPoint` (`Selection.swift`) for a match's span:
/// same document-row numbering, same highlighting a caller already knows
/// how to turn into a selection-shaped overlay.
///
/// Iterates via `Grid.reversedLogicalLines()`, which never materializes the
/// whole scrollback into one array (`PERFORMANCE.md` §4) — a search over a
/// full 100k-line scrollback is one lazy pass, not a copy. Newest-first
/// order is what makes the match cap useful: a truncated sweep keeps the
/// most recent matches — the ones the user was looking at when they typed
/// the query — rather than the document's oldest.
public enum Search {
    /// The match cap the shell searches with (P04). Unbounded results let a
    /// pathological document — a megabyte-long line of one repeated
    /// character is one — build a highlight list far larger than the
    /// renderer or the count label can ever use; the scan stops at the cap
    /// instead. 5_000 covers any query a person reads through via ⌘G while
    /// keeping the sweep's allocation and the renderer's quad list small.
    public static let defaultMatchLimit = 5_000

    /// The longest logical line a *regular expression* is run against (U16).
    ///
    /// This bounds an *ordinary* pattern's per-line cost and the work a
    /// single line can represent — a megabyte-long logical line is a real
    /// thing (`cat` of a binary produces several), and running any regex over
    /// one on every keystroke is not something to do.
    ///
    /// **It is deliberately not the guard against catastrophic patterns, and
    /// could not be.** `(a+)+b` doubles its cost every two characters:
    /// measured on this machine at 0.016 s for 18 characters, 0.52 s for 24
    /// and 8.0 s for 28. There is no line length at which such a pattern is
    /// affordable, so a length cap cannot be the answer — `isCatastrophic`
    /// is. Lines longer than this are skipped and counted in
    /// `RegexResult.skippedLongLines`, so the UI says the search was
    /// incomplete instead of quietly finding nothing.
    public static let regexLineLimit = 64_000

    /// How long a whole regex sweep may run before it stops and reports
    /// itself incomplete (U16).
    ///
    /// The cooperative `shouldStop` is polled between lines and per match,
    /// which covers a superseded query but not a pattern that is merely slow
    /// on every line. This is the wall clock that does. It is generous — a
    /// full-scrollback sweep of an ordinary pattern is milliseconds — so
    /// tripping it means the pattern, not the document.
    public static let regexTimeBudget: Duration = .milliseconds(500)

    /// What a regex sweep found, plus what it could not look at.
    public struct RegexResult: Sendable {
        public var matches: [SelectionRange]
        /// Logical lines skipped for exceeding `regexLineLimit`.
        public var skippedLongLines: Int
        /// Whether the sweep stopped on `regexTimeBudget` rather than
        /// finishing. The count it reports is a floor, not a total.
        public var timedOut: Bool

        public init(
            matches: [SelectionRange] = [], skippedLongLines: Int = 0, timedOut: Bool = false
        ) {
            self.matches = matches
            self.skippedLongLines = skippedLongLines
            self.timedOut = timedOut
        }

        /// Whether anything kept this sweep from seeing the whole document.
        public var isIncomplete: Bool { skippedLongLines > 0 || timedOut }
    }

    /// A pattern that could not be compiled — surfaced rather than treated
    /// as "no matches", because a half-typed regex is the normal state of a
    /// regex being typed and "no results" is the wrong thing to say about it.
    public static func isValidRegex(_ pattern: String, caseSensitive: Bool) -> Bool {
        compileRegex(pattern, caseSensitive: caseSensitive) != nil
    }

    /// Whether a pattern has the shape that makes a backtracking engine take
    /// exponential time — an unbounded quantifier applied to a group that
    /// itself repeats or alternates (`(a+)+`, `(a*)*`, `(a|a)+`).
    ///
    /// **Why a shape check and not a timeout.** Neither
    /// `NSRegularExpression` nor Swift's `Regex` exposes ICU's own time
    /// limit, so a single match attempt cannot be interrupted from outside:
    /// once ICU is handed such a pattern, the thread runs until it finishes.
    /// `regexTimeBudget` bounds the sweep *between* attempts and cannot
    /// bound one, and a length cap cannot either — the measurements on
    /// `regexLineLimit` show `(a+)+b` costing 8 seconds at 28 characters. The
    /// only place to stop it is before it starts.
    ///
    /// **Conservative on purpose.** It rejects some patterns that would in
    /// fact have been fine — `(\w+\s*)+` is refused along with `(a+)+` —
    /// because the alternative is a search that never returns and a core
    /// pinned for the life of the app. A refused pattern is reported as too
    /// slow, distinctly from one that does not compile, so the user knows to
    /// rewrite rather than to hunt for a typo. Every one of these has a
    /// linear equivalent: `(\w+\s*)+` is `[\w\s]+`.
    public static func isCatastrophic(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "[" {
                // A character class: `(`, `|` and `+` inside it are literal.
                index += 1
                while index < characters.count, characters[index] != "]" {
                    index += characters[index] == "\\" ? 2 : 1
                }
                index += 1
                continue
            }
            guard character == "(", let close = groupEnd(characters, from: index) else {
                index += 1
                continue
            }
            let body = Array(characters[(index + 1)..<close])
            guard let quantified = unboundedQuantifierEnd(characters, after: close) else {
                // Not a repeated group — step into it, since a nested one may
                // still be.
                index += 1
                continue
            }
            if bodyCanBacktrack(body) { return true }
            index = quantified
        }
        return false
    }

    /// The index of the `)` closing the group that opens at `start`, honouring
    /// nesting, escapes and character classes.
    private static func groupEnd(_ characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "[" {
                index += 1
                while index < characters.count, characters[index] != "]" {
                    index += characters[index] == "\\" ? 2 : 1
                }
                index += 1
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The index just past an unbounded quantifier (`*`, `+`, `{n,}`) sitting
    /// immediately after `close`, or `nil` if there is none.
    private static func unboundedQuantifierEnd(_ characters: [Character], after close: Int)
        -> Int?
    {
        var index = close + 1
        guard index < characters.count else { return nil }
        switch characters[index] {
        case "*", "+":
            index += 1
        case "{":
            guard let brace = characters[index...].firstIndex(of: "}") else { return nil }
            let inside = String(characters[(index + 1)..<brace])
            // `{2,}` is unbounded; `{2,4}` and `{2}` are not.
            guard inside.hasSuffix(",") else { return nil }
            index = brace + 1
        default:
            return nil
        }
        // A lazy or possessive marker does not change the shape.
        if index < characters.count, characters[index] == "?" || characters[index] == "+" {
            index += 1
        }
        return index
    }

    /// Whether a repeated group's body can match the same text more than one
    /// way — an unbounded quantifier inside it, or an alternation.
    private static func bodyCanBacktrack(_ body: [Character]) -> Bool {
        var index = 0
        while index < body.count {
            let character = body[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "[" {
                index += 1
                while index < body.count, body[index] != "]" {
                    index += body[index] == "\\" ? 2 : 1
                }
                index += 1
                continue
            }
            if character == "|" { return true }
            if character == "*" || character == "+" { return true }
            if character == "{", let brace = body[index...].firstIndex(of: "}") {
                if String(body[(index + 1)..<brace]).hasSuffix(",") { return true }
                index = brace + 1
                continue
            }
            index += 1
        }
        return false
    }

    private static func compileRegex(_ pattern: String, caseSensitive: Bool)
        -> NSRegularExpression?
    {
        guard !pattern.isEmpty else { return nil }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// Every match of a regular expression, oldest first (U16).
    ///
    /// Same budget and same cancellation as the substring path — the cap is
    /// the newest `maxMatches`, `shouldStop` is polled per line and per
    /// match — plus the per-line length bound above, which is what makes the
    /// cancellation *reachable* on a document that contains one enormous
    /// line.
    ///
    /// Zero-length matches (`a*`, `^`) advance by one character rather than
    /// looping: a pattern that matches nothing at every position is a
    /// pattern a person typed on the way to a longer one, not a reason to
    /// spin.
    public static func findRegex(
        _ pattern: String, in grid: Grid, caseSensitive: Bool = false,
        maxMatches: Int = .max, timeBudget: Duration = regexTimeBudget,
        shouldStop: () -> Bool = { false }
    ) -> RegexResult {
        guard maxMatches > 0, !isCatastrophic(pattern),
            let regex = compileRegex(pattern, caseSensitive: caseSensitive)
        else { return RegexResult() }
        var result = RegexResult()
        let deadline = ContinuousClock.now + timeBudget
        lineLoop: for logicalLine in grid.reversedLogicalLines() {
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            if shouldStop() { break }
            // Checked here as well as inside the match callback: a pattern
            // that is merely slow on every line never trips a per-match
            // check, because a line with no match calls the block no times.
            if ContinuousClock.now >= deadline {
                result.timedOut = true
                break
            }
            guard text.utf16.count <= regexLineLimit else {
                result.skippedLongLines += 1
                continue
            }
            let ns = text as NSString
            var found: [SelectionRange] = []
            regex.enumerateMatches(
                in: text, options: [], range: NSRange(location: 0, length: ns.length)
            ) { match, _, stop in
                guard let match, match.range.length > 0 else { return }
                // NSRange is UTF-16; the position table is by character.
                let prefix = ns.substring(to: match.range.location)
                let body = ns.substring(with: match.range)
                let startOffset = prefix.count
                let endOffset = startOffset + body.count - 1
                if let startPosition = logicalLine.position(at: startOffset),
                    let endPosition = logicalLine.position(at: endOffset)
                {
                    found.append(
                        SelectionRange(
                            start: SelectionPoint(
                                row: startPosition.row, column: startPosition.column),
                            end: SelectionPoint(row: endPosition.row, column: endPosition.column)))
                }
                if result.matches.count + found.count >= maxMatches || shouldStop()
                    || ContinuousClock.now >= deadline
                {
                    stop.pointee = true
                }
            }
            // Within a line the matches came out oldest-first; the outer walk
            // is newest-first, so each line's own order is reversed here and
            // the whole list is reversed once at the end.
            result.matches.append(contentsOf: found.reversed())
            if result.matches.count >= maxMatches || shouldStop() { break lineLoop }
            if ContinuousClock.now >= deadline {
                result.timedOut = true
                break lineLoop
            }
        }
        result.matches.reverse()
        return result
    }

    /// Every match of `query` in the document, oldest first. Empty for an
    /// empty query rather than matching every position.
    ///
    /// `maxMatches` bounds the result (`.max` opts out); a capped result is
    /// the *newest* `maxMatches` matches, so the caller can infer truncation
    /// from `count == maxMatches`. `shouldStop` is the cooperative
    /// cancellation point for background sweeps (A03): it is polled once per
    /// non-empty line and once per match, so a superseded search stops
    /// within one line's scan rather than running to completion. A stopped
    /// or capped scan returns the matches found so far.
    public static func find(
        _ query: String, in grid: Grid, caseSensitive: Bool = false,
        maxMatches: Int = .max, shouldStop: () -> Bool = { false }
    ) -> [SelectionRange] {
        guard !query.isEmpty, maxMatches > 0 else { return [] }
        var results: [SelectionRange] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        // Collected newest first (see the file header): lines scan from the
        // live screen backwards, and within a line the search runs
        // right-to-left, so the collection order is exactly reversed
        // document order and one `reverse` at the end restores the
        // oldest-first contract. Greedy right-to-left matching finds the
        // same *number* of matches as left-to-right (both are maximal
        // non-overlapping packings); only for a self-overlapping query
        // ("aa" in "aaa") does the choice of which occurrence is reported
        // change.
        lineLoop: for logicalLine in grid.reversedLogicalLines() {
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            // Polled per scanned line (empty ones cost nothing) and per
            // match — a cancelled sweep stops within one line's scan.
            if shouldStop() { break }
            var searchEnd = text.endIndex
            var searchEndOffset = text.count
            while searchEnd > text.startIndex,
                let found = text.range(
                    of: query, options: options.union(.backwards),
                    range: text.startIndex..<searchEnd)
            {
                guard !found.isEmpty else { break }
                // The character offsets advance with the matches — O(gap)
                // each, O(line) in total. Measuring every match from
                // `startIndex` rescans the line's prefix per match, which
                // is quadratic on a match-dense long line (P08).
                searchEndOffset -= text.distance(from: found.upperBound, to: searchEnd)
                let endOffset = searchEndOffset - 1
                let startOffset =
                    searchEndOffset - text.distance(from: found.lowerBound, to: found.upperBound)
                if let startPosition = logicalLine.position(at: startOffset),
                    let endPosition = logicalLine.position(at: endOffset)
                {
                    results.append(
                        SelectionRange(
                            start: SelectionPoint(row: startPosition.row, column: startPosition.column),
                            end: SelectionPoint(row: endPosition.row, column: endPosition.column)))
                }
                searchEnd = found.lowerBound
                searchEndOffset = startOffset
                if results.count >= maxMatches || shouldStop() { break lineLoop }
            }
        }
        results.reverse()
        return results
    }
}
