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
        public var skippedLongLines: Int
        /// The count is then a floor.
        public var timedOut: Bool

        public init(
            matches: [SelectionRange] = [], skippedLongLines: Int = 0, timedOut: Bool = false
        ) {
            self.matches = matches
            self.skippedLongLines = skippedLongLines
            self.timedOut = timedOut
        }

        public var isIncomplete: Bool { skippedLongLines > 0 || timedOut }
    }

    /// Not "no matches": a half-typed regex is the normal state of typing one.
    public static func isValidRegex(_ pattern: String, caseSensitive: Bool) -> Bool {
        compileRegex(pattern, caseSensitive: caseSensitive) != nil
    }

    /// Unbounded repetition of a group that repeats or alternates (`(a+)+`,
    /// `(a|a)+`). A conservative early rejection; progress callbacks also
    /// enforce cancellation and the time budget for shapes this check misses.
    /// Conservative: `(\w+\s*)+` is refused
    /// too — every such pattern has a linear form (`[\w\s]+`) — and a refusal is
    /// reported as too slow, not as a typo.
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
                index += 1
                continue
            }
            if bodyCanBacktrack(body) { return true }
            index = quantified
        }
        return false
    }

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

    /// Oldest first, with the substring path's cap and cancellation; the line
    /// bound is what makes cancellation reachable on one enormous line.
    /// Zero-length matches advance one character instead of spinning.
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
            guard !shouldStop() else { break }
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            // Here too: a line with no match never calls the block.
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
                in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)
            ) { match, _, stop in
                // Progress callbacks have no match. Check them before the
                // match guard so a failing backtracking attempt can stop too.
                if shouldStop() {
                    stop.pointee = true
                    return
                }
                if ContinuousClock.now >= deadline {
                    result.timedOut = true
                    stop.pointee = true
                    return
                }
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

    /// Oldest first; empty for an empty query. A capped result is the newest
    /// `maxMatches`. `shouldStop` is polled per line and per match.
    public static func find(
        _ query: String, in grid: Grid, caseSensitive: Bool = false,
        maxMatches: Int = .max, shouldStop: () -> Bool = { false }
    ) -> [SelectionRange] {
        guard !query.isEmpty, maxMatches > 0 else { return [] }
        var results: [SelectionRange] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        // Collected newest first and reversed once. Right-to-left finds the same
        // number of matches; only which occurrence of a self-overlapping query
        // ("aa" in "aaa") is reported changes.
        //
        // ASCII on both sides — the common case — matches the cells directly, no
        // `String` per line. A line only the `String` path can represent falls back
        // on its own.
        let needle = asciiNeedle(query, caseSensitive: caseSensitive)
        let fold = caseSensitive ? asciiIdentity : asciiFold
        // Matched right to left as KMP over the reversed needle: each byte
        // is read once, however much of the needle a near miss repeats.
        // Comparing from every start position cost the line's length times
        // the needle's — `a`×4095 then `b` against a long line of `a`.
        let reversedNeedle = needle.map { Array($0.reversed()) } ?? []
        let failure = needle == nil ? [] : failureTable(reversedNeedle)
        var historyReader = Scrollback.ASCIIReader()
        var haystack = ContiguousArray<UInt8>()
        var haystackRows = ContiguousArray<Int32>()
        var haystackColumns = ContiguousArray<Int32>()

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
        lineLoop: for span in grid.reversedLogicalLineSpans() {
            if let needle,
                grid.fillWithASCIILogicalLine(
                    firstRow: span.firstRow, lastRow: span.lastRow,
                    text: &haystack, rows: &haystackRows, columns: &haystackColumns,
                    historyReader: &historyReader, nonASCIIIsOpaque: nonASCIIIsOpaque)
            {
                guard !haystack.isEmpty else { continue }
                if shouldStop() { break }
                // The rightmost match first, then only what lies wholly to
                // its left: a self-overlapping query ("aa" in "aaa") reports
                // the later occurrence, as before.
                let count = needle.count
                var matched = 0
                var index = haystack.count - 1
                var sincePoll = 0
                while index >= 0 {
                    if matched == 0, index >= 15 {
                        let lanes = haystack.withUnsafeBytes {
                            $0.loadUnaligned(fromByteOffset: index - 15, as: SIMD16<UInt8>.self)
                        }
                        let upper = (lanes .>= SIMD16(repeating: 0x41)) .& (lanes .<= SIMD16(repeating: 0x5A))
                        let folded = caseSensitive ? lanes : lanes.replacing(with: lanes &+ SIMD16(repeating: 0x20), where: upper)
                        if !any(folded .== SIMD16(repeating: reversedNeedle[0])) {
                            index -= 16
                            sincePoll += 16
                            if sincePoll >= stopPollInterval { sincePoll = 0; if shouldStop() { break lineLoop } }
                            continue
                        }
                    }
                    let byte = fold[Int(haystack[index])]
                    while matched > 0, byte != reversedNeedle[matched] {
                        matched = failure[matched - 1]
                    }
                    if byte == reversedNeedle[matched] { matched += 1 }
                    if matched == count {
                        let last = index + count - 1
                        results.append(
                            SelectionRange(
                                start: SelectionPoint(
                                    row: Int(haystackRows[index]),
                                    column: Int(haystackColumns[index])),
                                end: SelectionPoint(
                                    row: Int(haystackRows[last]),
                                    column: Int(haystackColumns[last]))))
                        matched = 0
                        if results.count >= maxMatches || shouldStop() { break lineLoop }
                    }
                    index -= 1
                    // A cancelled sweep stops inside a long line too, not
                    // only between lines and at matches.
                    sincePoll += 1
                    if sincePoll >= stopPollInterval {
                        sincePoll = 0
                        if shouldStop() { break lineLoop }
                    }
                }
                continue
            }

            let logicalLine = grid.logicalLine(
                firstRow: span.firstRow, lastRow: span.lastRow)
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            if shouldStop() { break }
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
