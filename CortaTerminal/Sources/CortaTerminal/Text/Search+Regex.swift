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

extension Search {
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
                resumeBeforeLine(logicalLine, in: grid, result: &result)
                break
            }
        }
        result.matches.reverse()
        return result
    }

    private static func resumeBeforeLine(_ line: LogicalLine, in grid: Grid, result: inout RegexResult) {
        guard line.firstRow > grid.documentRowRange.lowerBound else { return }
        result.timedOut = true
        result.resumeRow = line.firstRow - 1
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
