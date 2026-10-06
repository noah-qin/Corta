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

/// ⌘-click URL detection over logical lines. Only `http`, `https` and
/// `mailto` can match at all (`SECURITY.md` §2.4), so no click path can carry
/// `file://` or a custom scheme to `NSWorkspace`. OSC 8 links are checked
/// first — there text and target can differ, which is why the tooltip names
/// the target.
public enum LinkDetection {
    public struct Link: Equatable, Sendable {
        public var url: String
        public var range: SelectionRange
    }

    /// Detection only; `NSWorkspace` parses before opening.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://|mailto:)\S+"#, options: [.caseInsensitive])

    /// This runs on every mouse move; a megabyte minified line must not become
    /// an unbounded regex pass on the main thread. Past it, only OSC 8 links
    /// resolve. 100k cells is ~2,000 wrapped rows at 50 columns.
    public static let maxPatternScanCells = 100_000

    /// Prose punctuation: `See https://example.com.`, `(https://…)`.
    private static let trailingTrim: Set<UInt16> = [46, 44, 59, 58, 33, 63, 39, 34]

    /// OSC 8 wins: the program named the target.
    public static func link(at point: SelectionPoint, in grid: Grid) -> Link? {
        if let explicit = hyperlink(at: point, in: grid) { return explicit }
        let span = grid.logicalLineRowSpan(containing: point.row)
        guard (span.last - span.first + 1) * grid.columns <= maxPatternScanCells
        else { return nil }
        let line = grid.logicalLine(containing: point.row)
        guard !line.text.isEmpty else { return nil }
        return links(in: line).first { $0.range.start <= point && point <= $0.range.end }
    }

    /// Widened to the contiguous run sharing the id, for hover and tooltip.
    public static func hyperlink(at point: SelectionPoint, in grid: Grid) -> Link? {
        let line = grid.documentLine(point.row)
        let id = line[point.column].hyperlink
        guard !id.isNone, let url = grid.hyperlinks.url(for: id) else { return nil }
        var first = point.column
        while first > 0, line[first - 1].hyperlink == id { first -= 1 }
        var last = point.column
        while last + 1 < line.count, line[last + 1].hyperlink == id { last += 1 }
        return Link(
            url: url,
            range: SelectionRange(
                start: SelectionPoint(row: point.row, column: first),
                end: SelectionPoint(row: point.row, column: last)))
    }

    public static func links(in line: LogicalLine) -> [Link] {
        let text = line.text
        let nsText = text as NSString
        var cursor = CharacterOffsetCursor(text)
        func characterOffset(atUTF16Offset target: Int) -> Int? {
            cursor.characterOffset(atUTF16Offset: target)
        }

        var links: [Link] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            var url = match.range
            // Count ASCII delimiters once. Re-scanning on each removed
            // closer made a hostile suffix quadratic on the hover path.
            var counts: [UInt16: Int] = [:]
            for index in url.location..<(url.location + url.length) {
                let unit = nsText.character(at: index)
                if unit == 40 || unit == 41 || unit == 91 || unit == 93 || unit == 123 || unit == 125 {
                    counts[unit, default: 0] += 1
                }
            }
            // An unbalanced `)` is prose too.
            while url.length > 0 {
                let last = nsText.character(at: url.length - 1 + url.location)
                if trailingTrim.contains(last) {
                    url.length -= 1
                } else if last == 41 || last == 93 || last == 125 {
                    let opener: UInt16 = last == 41 ? 40 : last == 93 ? 91 : 123
                    if counts[opener, default: 0] < counts[last, default: 0] {
                        counts[last, default: 0] -= 1
                        url.length -= 1
                    } else { break }
                } else { break }
            }
            guard url.length > 0,
                let startOffset = characterOffset(atUTF16Offset: url.location),
                let endOffset = characterOffset(atUTF16Offset:
                    nsText.rangeOfComposedCharacterSequence(at: url.location + url.length - 1).location),
                let startPosition = line.position(at: startOffset),
                let endPosition = line.position(at: endOffset)
            else { continue }
            links.append(
                Link(
                    url: nsText.substring(with: url),
                    range: SelectionRange(
                        start: SelectionPoint(row: startPosition.row, column: startPosition.column),
                        end: SelectionPoint(row: endPosition.row, column: endPosition.column))))
        }
        return links
    }
}

/// Character offsets of ascending UTF-16 offsets, walking both forward
/// together — O(line) for all the matches in a line. Converting each match
/// from the start is quadratic (25,000 `a:1` matches on one line took 7 s on
/// the main thread), and a CJK prefix makes the two units differ.
struct CharacterOffsetCursor {
    private let text: String
    private var utf16Cursor: String.Index
    private var utf16CursorOffset = 0
    private var characterCursor: String.Index
    private var characterCursorOffset = 0

    init(_ text: String) {
        self.text = text
        utf16Cursor = text.utf16.startIndex
        characterCursor = text.startIndex
    }

    /// `nil` for an offset behind the cursor or inside a character.
    mutating func characterOffset(atUTF16Offset target: Int) -> Int? {
        guard target >= utf16CursorOffset,
            let newUTF16 = text.utf16.index(
                utf16Cursor, offsetBy: target - utf16CursorOffset,
                limitedBy: text.utf16.endIndex),
            let newCharacter = String.Index(newUTF16, within: text)
        else { return nil }
        characterCursorOffset += text.distance(from: characterCursor, to: newCharacter)
        characterCursor = newCharacter
        utf16Cursor = newUTF16
        utf16CursorOffset = target
        return characterCursorOffset
    }
}
