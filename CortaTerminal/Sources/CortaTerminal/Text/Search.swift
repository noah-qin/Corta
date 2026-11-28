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

        var scalarOpacity = ScalarOpacity()
        // A query with a scalar that stays non-ASCII under case folding and
        // canonical decomposition cannot equal any text made only of ASCII, so a
        // line of ASCII cells is skipped without building a `String` for it.
        let cannotMatchASCIIOnlyLine = matcher == nil && queryNeedsNonASCII(query, caseSensitive: caseSensitive)
        // The ideographs the query names, which only a line holding those very
        // scalars can match (an ideograph has no case, and the one canonical
        // equivalence that reaches one, from a compatibility ideograph, is
        // checked per row): a history line without them is skipped from its
        // row index, without building its text.
        let requiredIdeographs = cannotMatchASCIIOnlyLine ? unifiedIdeographs(in: query) : []
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
                    historyReader: &historyReader, nonASCIIIsOpaque: { scalarOpacity.isOpaque($0) })
            {
                guard !haystack.text.isEmpty else { continue }
                stopped = shouldStop() || matcher.scan(haystack, into: &matches, shouldStop: shouldStop)
            } else {
                let line = grid.logicalLine(firstRow: span.firstRow, lastRow: span.lastRow)
                guard !line.text.isEmpty else { continue }
                stopped = shouldStop() || scanText(
                    of: line, for: query, options: options, into: &matches, shouldStop: shouldStop)
            }
            if stopped { break }
        }
        var results = matches.ranges
        results.reverse()
        return results
    }

    private struct ScalarOpacity {
        // Cache per scalar, rather than shaping the entire mixed-text line
        // after an ASCII walk has already visited it. Combining/format scalars
        // and scalars folding into ASCII retain the full String implementation.
        private var opaqueScalars: [UInt32: Bool] = [:]
        mutating func isOpaque(_ value: UInt32) -> Bool {
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
    }

    private static func unifiedIdeographs(in query: String) -> [UInt32] {
        var required: [UInt32] = []
        for scalar in query.unicodeScalars where isUnifiedIdeograph(scalar.value) {
            if !required.contains(scalar.value) { required.append(scalar.value) }
        }
        return required
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
