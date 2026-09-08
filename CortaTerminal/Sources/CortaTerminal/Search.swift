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
    /// Plain substring search is linear and safe on any line. A regular
    /// expression is not: `NSRegularExpression` backtracks, a pattern like
    /// `(a+)+b` is exponential in the input's length, and there is no
    /// timeout to hand it — the only cancellation `shouldStop` provides is
    /// *between* lines, so a single pathological line would hang the sweep
    /// with the cancellation check unreachable. A megabyte-long logical line
    /// is a real thing (one `cat` of a binary produces several), so the
    /// bound is on the input rather than on the pattern, which cannot be
    /// analysed cheaply. Lines longer than this are skipped by the regex
    /// path and reported through `Result.skippedLongLines`, so the UI can
    /// say the search was incomplete instead of quietly finding nothing.
    public static let regexLineLimit = 64_000

    /// What a regex sweep found, plus what it could not look at.
    public struct RegexResult: Sendable {
        public var matches: [SelectionRange]
        /// Logical lines skipped for exceeding `regexLineLimit`.
        public var skippedLongLines: Int

        public init(matches: [SelectionRange] = [], skippedLongLines: Int = 0) {
            self.matches = matches
            self.skippedLongLines = skippedLongLines
        }
    }

    /// A pattern that could not be compiled — surfaced rather than treated
    /// as "no matches", because a half-typed regex is the normal state of a
    /// regex being typed and "no results" is the wrong thing to say about it.
    public static func isValidRegex(_ pattern: String, caseSensitive: Bool) -> Bool {
        compileRegex(pattern, caseSensitive: caseSensitive) != nil
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
        maxMatches: Int = .max, shouldStop: () -> Bool = { false }
    ) -> RegexResult {
        guard maxMatches > 0,
            let regex = compileRegex(pattern, caseSensitive: caseSensitive)
        else { return RegexResult() }
        var result = RegexResult()
        lineLoop: for logicalLine in grid.reversedLogicalLines() {
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            if shouldStop() { break }
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
                if result.matches.count + found.count >= maxMatches || shouldStop() {
                    stop.pointee = true
                }
            }
            // Within a line the matches came out oldest-first; the outer walk
            // is newest-first, so each line's own order is reversed here and
            // the whole list is reversed once at the end.
            result.matches.append(contentsOf: found.reversed())
            if result.matches.count >= maxMatches || shouldStop() { break lineLoop }
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
