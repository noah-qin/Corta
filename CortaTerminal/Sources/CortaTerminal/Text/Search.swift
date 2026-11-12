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

/// Scrollback search over logical lines, so a match across a soft wrap is
/// found whole. Newest first and lazy (`reversedLogicalLines()`): a capped
/// sweep keeps the matches the user was looking at.
public enum Search {
    /// A megabyte line of one repeated character would otherwise build a
    /// highlight list no renderer can use.
    public static let defaultMatchLimit = 5_000

    /// Bounds an ordinary pattern's per-line cost (`cat` of a binary yields
    /// megabyte lines). Catastrophic patterns have an early shape check and
    /// progress-callback cancellation. Skipped lines are counted so the UI
    /// says the search was incomplete.
    public static let regexLineLimit = 64_000

    /// `shouldStop` catches a superseded query, not a pattern slow on every
    /// line; this does. Tripping it means the pattern, not the document.
    public static let regexTimeBudget: Duration = .milliseconds(500)

    public struct RegexResult: Sendable {
        public var matches: [SelectionRange]
        /// Lines the sweep did not search: past `regexLineLimit`, or a line
        /// whose matches could not be found within one whole time budget.
        public var unsearchedLines: Int
        /// The count is then a floor.
        public var timedOut: Bool
        /// Where an older sweep resumes: the last row of the next logical
        /// line to read, in the swept grid's coordinates. Nil when nothing
        /// older remains, or the sweep was superseded. Pass it back as
        /// `findRegex(_:in:from:)`'s `resumeRow`.
        public var resumeRow: Int?

        public init(
            matches: [SelectionRange] = [], unsearchedLines: Int = 0, timedOut: Bool = false,
            resumeRow: Int? = nil
        ) {
            self.matches = matches
            self.unsearchedLines = unsearchedLines
            self.timedOut = timedOut
            self.resumeRow = resumeRow
        }

        public var isIncomplete: Bool { unsearchedLines > 0 || timedOut }
    }

    /// Not "no matches": a half-typed regex is the normal state of typing one.
    public static func isValidRegex(_ pattern: String, caseSensitive: Bool) -> Bool {
        compileRegex(pattern, caseSensitive: caseSensitive) != nil
    }

    /// Unbounded repetition of a group whose iterations can split the same
    /// text more than one way — the shapes that backtrack exponentially. Two
    /// are refused:
    ///
    /// - an unbounded repeat inside the group that nothing required in the
    ///   iteration separates from the next one: `(a+)+`, `(.*)*`,
    ///   `(\w+\s?)+`. `(\d+\.)+` passes: each iteration must end on a `.`,
    ///   which `\d+` cannot take.
    /// - alternatives that can start on the same character, or match nothing:
    ///   `(a|a)+`, `(a|ab)+`. `(a|b)+` and `(foo|bar)*` pass.
    ///
    /// Conservative where it cannot tell (`.`, a negated class, a
    /// backreference count as any character), and an early rejection only:
    /// progress callbacks still enforce cancellation and the time budget for
    /// shapes it misses. A refusal is reported as too slow, not as a typo.
    public static func isCatastrophic(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if skipLiteral(characters, at: &index) { continue }
            guard character == "(", let close = groupEnd(characters, from: index) else {
                index += 1
                continue
            }
            let body = Array(characters[(index + 1)..<close])
            guard let quantified = unboundedQuantifierEnd(characters, after: close) else {
                index += 1
                continue
            }
            if RepeatShape.isAmbiguous(body) { return true }
            index = quantified
        }
        return false
    }

    /// Steps over an escape (`\\x`) or a whole character class (`[...]`) at
    /// `index`, which hold no group to find; `false` leaves `index` alone.
    private static func skipLiteral(_ characters: [Character], at index: inout Int) -> Bool {
        switch characters[index] {
        case "\\":
            index += 2
        case "[":
            index += 1
            while index < characters.count, characters[index] != "]" {
                index += characters[index] == "\\" ? 2 : 1
            }
            index += 1
        default:
            return false
        }
        return true
    }

    private static func groupEnd(_ characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            let character = characters[index]
            if skipLiteral(characters, at: &index) { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

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

    private static func compileRegex(_ pattern: String, caseSensitive: Bool)
        -> NSRegularExpression?
    {
        guard !pattern.isEmpty else { return nil }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// Oldest first, with the substring path's cap and cancellation; the line
    /// bound is what makes cancellation reachable on one enormous line.
    /// Zero-length matches advance one character instead of spinning.
    ///
    /// `resumeRow` continues a sweep that ran out of time: the last row of the
    /// next logical line to read, from an earlier result's `resumeRow`. It
    /// must be a logical line's last row (the earlier result guarantees it),
    /// and nil starts from the newest line.
    public static func findRegex(
        _ pattern: String, in grid: Grid, caseSensitive: Bool = false,
        maxMatches: Int = .max, timeBudget: Duration = regexTimeBudget,
        from resumeRow: Int? = nil, downToRow: Int? = nil, shouldStop: () -> Bool = { false }
    ) -> RegexResult {
        guard maxMatches > 0, !isCatastrophic(pattern),
            let regex = compileRegex(pattern, caseSensitive: caseSensitive)
        else { return RegexResult() }
        var result = RegexResult()
        let sweep = RegexSweep(regex: regex, maxMatches: maxMatches, deadline: SuspendingClock.now + timeBudget)
        let lines =
            resumeRow.map { grid.reversedLogicalLines(startingAtLastRow: $0) }
            ?? grid.reversedLogicalLines()
        // Lines fully read in this call. A line that cannot be finished in one
        // whole budget is left unsearched and the sweep moves on; retrying it
        // from its start would spend the next budget the same way, forever.
        var linesRead = 0
        for logicalLine in lines {
            // Lines at or below `downToRow` were searched by an earlier slice.
            if let downToRow, logicalLine.lastRow <= downToRow { break }
            if shouldStop() { break }
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            // Here too: a line with no match never calls the block.
            if sweep.isExpired {
                result.timedOut = true
                result.resumeRow = logicalLine.lastRow
                break
            }
            guard text.utf16.count <= regexLineLimit else {
                result.unsearchedLines += 1
                linesRead += 1
                continue
            }
            let found = sweep.matches(in: logicalLine, result: &result, shouldStop: shouldStop)
            if result.timedOut {
                resumeAfterLineTimeout(in: logicalLine, grid: grid, linesRead: linesRead, result: &result)
                break
            }
            result.matches.append(contentsOf: found.reversed())
            linesRead += 1
            if result.matches.count >= maxMatches || shouldStop() { break }
            if sweep.isExpired {
                // Older than this line is unread.
                if logicalLine.firstRow > grid.documentRowRange.lowerBound {
                    result.timedOut = true
                    result.resumeRow = logicalLine.firstRow - 1
                }
                break
            }
        }
        result.matches.reverse()
        return result
    }

    /// Where the sweep resumes when the budget ended inside a logical line.
    /// A line reached after others were read gets a fresh budget; one that a
    /// whole budget could not finish (nothing read before it) never would, so
    /// it is left unsearched and counted rather than retried forever.
    private static func resumeAfterLineTimeout(
        in logicalLine: LogicalLine, grid: Grid, linesRead: Int, result: inout RegexResult
    ) {
        guard linesRead == 0 else {
            result.resumeRow = logicalLine.lastRow
            return
        }
        result.unsearchedLines += 1
        guard logicalLine.firstRow > grid.documentRowRange.lowerBound else {
            result.resumeRow = nil
            return
        }
        result.resumeRow = logicalLine.firstRow - 1
    }

    /// One regex sweep's fixed inputs: the expression, the cap and the deadline.
    private struct RegexSweep {
        let regex: NSRegularExpression
        let maxMatches: Int
        let deadline: SuspendingClock.Instant

        var isExpired: Bool { SuspendingClock.now >= deadline }

        /// The line's matches in text order. Sets `result.timedOut` when the
        /// budget runs out inside the line.
        func matches(
            in logicalLine: LogicalLine, result: inout RegexResult, shouldStop: () -> Bool
        ) -> [SelectionRange] {
            let text = logicalLine.text
            let nsText = text as NSString
            var found: [SelectionRange] = []
            let already = result.matches.count
            var timedOut = false
            var character = text.startIndex
            var characterOffset = 0
            var nextUTF16Offset = 0
            func position(containingUTF16Offset offset: Int) -> Int {
                while nextUTF16Offset <= offset, character < text.endIndex {
                    let next = text.index(after: character)
                    nextUTF16Offset += text[character..<next].utf16.count
                    character = next
                    characterOffset += 1
                }
                return characterOffset - 1
            }
            regex.enumerateMatches(
                in: text, options: [.reportProgress], range: NSRange(location: 0, length: nsText.length)
            ) { match, _, stop in
                // Progress callbacks have no match. Check them before the
                // match guard so a failing backtracking attempt can stop too.
                if shouldStop() {
                    stop.pointee = true
                    return
                }
                if isExpired {
                    timedOut = true
                    stop.pointee = true
                    return
                }
                guard let match, match.range.length > 0 else { return }
                // Regex reports disjoint ranges in text order. Walk each
                // grapheme once, including matches inside a grapheme cluster.
                let startOffset = position(containingUTF16Offset: match.range.location)
                let endOffset = position(containingUTF16Offset: NSMaxRange(match.range) - 1)
                if let startPosition = logicalLine.position(at: startOffset),
                    let endPosition = logicalLine.position(at: endOffset)
                {
                    found.append(
                        SelectionRange(
                            start: SelectionPoint(row: startPosition.row, column: startPosition.column),
                            end: SelectionPoint(row: endPosition.row, column: endPosition.column)))
                }
                if already + found.count >= maxMatches || shouldStop() || isExpired {
                    stop.pointee = true
                }
            }
            if timedOut { result.timedOut = true }
            return found
        }
    }
}

// MARK: - Plain text

extension Search {
    /// A table, not `| 0x20` (which folds `[` into `{`). Equivalent to
    /// `.caseInsensitive` only for ASCII — the Kelvin sign and Turkish `i` are
    /// outside it, so the fast path refuses non-ASCII.
    private static let asciiFold: [UInt8] = (0...255).map { byte in
        (0x41...0x5A).contains(byte) ? UInt8(byte + 0x20) : UInt8(byte)
    }

    /// Chosen once per sweep, so the inner comparison has no branch and reads
    /// no global per byte — the shape of a measured frame-CPU regression.
    private static let asciiIdentity: [UInt8] = (0...255).map { UInt8($0) }

    private static func asciiNeedle(_ query: String, caseSensitive: Bool) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(query.utf8.count)
        for byte in query.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append(caseSensitive ? byte : asciiFold[Int(byte)])
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// The Knuth–Morris–Pratt failure function: for each prefix of
    /// `pattern`, the length of its longest proper prefix that is also a
    /// suffix. It is what lets a mismatch resume without re-reading text.
    private static func failureTable(_ pattern: [UInt8]) -> [Int] {
        var table = [Int](repeating: 0, count: pattern.count)
        var matched = 0
        for index in 1..<max(1, pattern.count) {
            while matched > 0, pattern[index] != pattern[matched] { matched = table[matched - 1] }
            if pattern[index] == pattern[matched] { matched += 1 }
            table[index] = matched
        }
        return table
    }

    /// Bytes scanned between `shouldStop` polls inside one logical line.
    static let stopPollInterval = 64 * 1024

    /// Matches collected newest first, up to a cap.
    private struct Matches {
        let limit: Int
        var ranges: [SelectionRange] = []
        var isFull: Bool { ranges.count >= limit }
    }

    /// Oldest first; empty for an empty query. A capped result is the newest
    /// `maxMatches`. `shouldStop` is polled per line and per match.
    public static func find(
        _ query: String, in grid: Grid, caseSensitive: Bool = false,
        maxMatches: Int = .max, shouldStop: () -> Bool = { false }
    ) -> [SelectionRange] {
        guard !query.isEmpty, maxMatches > 0 else { return [] }
        var matches = Matches(limit: maxMatches)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        // Collected newest first and reversed once. Right-to-left finds the same
        // number of matches; only which occurrence of a self-overlapping query
        // ("aa" in "aaa") is reported changes.
        //
        // ASCII on both sides — the common case — matches the cells directly, no
        // `String` per line. A line only the `String` path can represent falls back
        // on its own.
        let matcher = asciiNeedle(query, caseSensitive: caseSensitive).map {
            ReverseMatcher(needle: $0, caseSensitive: caseSensitive)
        }
        var historyReader = Scrollback.ASCIIReader()
        var haystack = Grid.ASCIILine()

        // Cache per scalar, rather than shaping the entire mixed-text line
        // after an ASCII walk has already visited it. Combining/format scalars
        // and scalars folding into ASCII retain the full String implementation.
        var opaqueScalars: [UInt32: Bool] = [:]
        func nonASCIIIsOpaque(_ value: UInt32) -> Bool {
            if let cached = opaqueScalars[value] { return cached }
            guard let scalar = Unicode.Scalar(value) else { return false }
            let opaque: Bool
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format:
                opaque = false
            default:
                opaque = !String(scalar).folding(options: .caseInsensitive, locale: nil)
                    .utf8.contains { $0 < 0x80 }
            }
            opaqueScalars[value] = opaque
            return opaque
        }
        // A query with a scalar that stays non-ASCII under case folding and
        // canonical decomposition cannot equal any text made only of ASCII, so a
        // line of ASCII cells is skipped without building a `String` for it.
        let cannotMatchASCIIOnlyLine = matcher == nil && queryNeedsNonASCII(query, caseSensitive: caseSensitive)
        // The ideographs the query names, which only a line holding those very
        // scalars can match (an ideograph has no case, and the one canonical
        // equivalence that reaches one, from a compatibility ideograph, is
        // checked per row): a history line without them is skipped from its
        // row index, without building its text.
        var requiredIdeographs: [UInt32] = []
        if cannotMatchASCIIOnlyLine {
            for scalar in query.unicodeScalars where isUnifiedIdeograph(scalar.value) {
                if !requiredIdeographs.contains(scalar.value) { requiredIdeographs.append(scalar.value) }
            }
        }
        for span in grid.reversedLogicalLineSpans() {
            let stopped: Bool
            if cannotMatchASCIIOnlyLine,
                grid.fillWithASCIILogicalLine(
                    firstRow: span.firstRow, lastRow: span.lastRow, into: &haystack,
                    historyReader: &historyReader)
            {
                // The default `nonASCIIIsOpaque` refuses at the first non-ASCII cell
                // or cluster, so `true` here means every cell was ASCII.
                if !haystack.text.isEmpty, shouldStop() { break }
                continue
            } else if !requiredIdeographs.isEmpty,
                grid.historyLacksRequiredScalar(
                    requiredIdeographs, firstRow: span.firstRow, lastRow: span.lastRow, reader: &historyReader)
            {
                if shouldStop() { break }
                continue
            } else if let matcher,
                grid.fillWithASCIILogicalLine(
                    firstRow: span.firstRow, lastRow: span.lastRow, into: &haystack,
                    historyReader: &historyReader, nonASCIIIsOpaque: nonASCIIIsOpaque)
            {
                guard !haystack.text.isEmpty else { continue }
                if shouldStop() { break }
                stopped = matcher.scan(haystack, into: &matches, shouldStop: shouldStop)
            } else {
                let line = grid.logicalLine(firstRow: span.firstRow, lastRow: span.lastRow)
                guard !line.text.isEmpty else { continue }
                if shouldStop() { break }
                stopped = scanText(of: line, for: query, options: options, into: &matches, shouldStop: shouldStop)
            }
            if stopped { break }
        }
        var results = matches.ranges
        results.reverse()
        return results
    }

    /// CJK Unified Ideographs and extensions A to H, not the compatibility blocks.
    static func isUnifiedIdeograph(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0x20000...0x323AF).contains(value) && !(0x2F800...0x2FA1F).contains(value)
    }

    /// True when `query` holds a scalar that no ASCII text can produce under the
    /// comparison `find` uses: a letter, number, symbol or punctuation scalar
    /// whose case-folded (unless `caseSensitive`) canonical decomposition still
    /// has a non-ASCII scalar. The Kelvin sign and U+037E fold or decompose to
    /// ASCII and so do not count. Marks, format and control scalars never count:
    /// the comparison may ignore or reorder them, so a query made of them takes
    /// the `String` path on every line, as before.
    static func queryNeedsNonASCII(_ query: String, caseSensitive: Bool) -> Bool {
        for scalar in query.unicodeScalars where scalar.value >= 0x80 {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber,
                .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation,
                .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                var text = String(scalar)
                if !caseSensitive { text = text.folding(options: .caseInsensitive, locale: nil) }
                text = text.decomposedStringWithCanonicalMapping
                if text.unicodeScalars.contains(where: { $0.value >= 0x80 }) { return true }
            default:
                continue
            }
        }
        return false
    }

    /// An ASCII query, reversed for a right-to-left KMP scan of a line's
    /// bytes: each byte is read once, however much of the needle a near miss
    /// repeats. Comparing from every start position cost the line's length
    /// times the needle's — `a`×4095 then `b` against a long line of `a`.
    private struct ReverseMatcher {
        let needle: [UInt8]
        let failure: [Int]
        let fold: [UInt8]
        let caseSensitive: Bool

        init(needle: [UInt8], caseSensitive: Bool) {
            self.needle = needle.reversed()
            failure = Search.failureTable(self.needle)
            fold = caseSensitive ? Search.asciiIdentity : Search.asciiFold
            self.caseSensitive = caseSensitive
        }

        /// Adds the line's matches, rightmost first, then only what lies
        /// wholly to its left: a self-overlapping query ("aa" in "aaa")
        /// reports the later occurrence. True when the sweep must stop.
        func scan(_ line: Grid.ASCIILine, into matches: inout Matches, shouldStop: () -> Bool) -> Bool {
            let haystack = line.text
            let count = needle.count
            var matched = 0
            var index = haystack.count - 1
            var sincePoll = 0
            let needleTail = SIMD16(repeating: needle[0])
            while index >= 0 {
                if matched == 0, index >= 15, !mayEnd(in: haystack, at: index, matching: needleTail) {
                    index -= 16
                    sincePoll += 16
                    if sincePoll >= Search.stopPollInterval { sincePoll = 0; if shouldStop() { return true } }
                    continue
                }
                let byte = fold[Int(haystack[index])]
                while matched > 0, byte != needle[matched] {
                    matched = failure[matched - 1]
                }
                if byte == needle[matched] { matched += 1 }
                if matched == count {
                    let last = index + count - 1
                    matches.ranges.append(
                        SelectionRange(
                            start: SelectionPoint(row: Int(line.rows[index]), column: Int(line.columns[index])),
                            end: SelectionPoint(row: Int(line.rows[last]), column: Int(line.columns[last]))))
                    matched = 0
                    if matches.isFull || shouldStop() { return true }
                }
                index -= 1
                // A cancelled sweep stops inside a long line too, not
                // only between lines and at matches.
                sincePoll += 1
                if sincePoll >= Search.stopPollInterval {
                    sincePoll = 0
                    if shouldStop() { return true }
                }
            }
            return false
        }

        /// Whether the 16 bytes ending at `index` hold the needle's last
        /// byte; when they don't, no match ends among them.
        @inline(__always)
        private func mayEnd(in haystack: ContiguousArray<UInt8>, at index: Int, matching last: SIMD16<UInt8>) -> Bool {
            let lanes = haystack.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: index - 15, as: SIMD16<UInt8>.self)
            }
            let upper = (lanes .>= SIMD16(repeating: 0x41)) .& (lanes .<= SIMD16(repeating: 0x5A))
            let folded = caseSensitive ? lanes : lanes.replacing(with: lanes &+ SIMD16(repeating: 0x20), where: upper)
            return any(folded .== last)
        }
    }

    /// The `String` path, for a line ASCII cannot represent. True when the
    /// sweep must stop.
    private static func scanText(
        of logicalLine: LogicalLine, for query: String, options: String.CompareOptions,
        into matches: inout Matches, shouldStop: () -> Bool
    ) -> Bool {
        let text = logicalLine.text
        var searchEnd = text.endIndex
        var searchEndOffset = text.count
        while searchEnd > text.startIndex,
            let found = text.range(
                of: query, options: options.union(.backwards),
                range: text.startIndex..<searchEnd)
        {
            guard !found.isEmpty else { break }
            // Advance offsets with the matches; measuring each from the start is
            // quadratic on a match-dense line.
            searchEndOffset -= text.distance(from: found.upperBound, to: searchEnd)
            let endOffset = searchEndOffset - 1
            let startOffset =
                searchEndOffset - text.distance(from: found.lowerBound, to: found.upperBound)
            if let startPosition = logicalLine.position(at: startOffset),
                let endPosition = logicalLine.position(at: endOffset)
            {
                matches.ranges.append(
                    SelectionRange(
                        start: SelectionPoint(row: startPosition.row, column: startPosition.column),
                        end: SelectionPoint(row: endPosition.row, column: endPosition.column)))
            }
            searchEnd = found.lowerBound
            searchEndOffset = startOffset
            if matches.isFull || shouldStop() { return true }
        }
        return false
    }
}
