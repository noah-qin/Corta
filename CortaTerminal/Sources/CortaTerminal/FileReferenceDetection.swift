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

/// `path:line[:column]` in output — what compilers, `grep -n` and tracebacks
/// print — as something to click.
///
/// **Not a URL, and the scheme allowlist stays closed.** Output only
/// supplies text; the app resolves it against a directory it knows is local
/// and checks the file exists. Allowing `file` would let any output hand
/// `NSWorkspace` a path.
///
/// **A bare path is not detected**: prose is full of `and/or`. Requiring
/// `:line` is the shape a tool emits.
public enum FileReferenceDetection {
    public struct Reference: Equatable, Sendable {
        /// As written; only the app knows the pane's directory and whether it is
        /// local.
        public var path: String
        public var line: Int
        public var column: Int?
        public var range: SelectionRange

        public init(path: String, line: Int, column: Int? = nil, range: SelectionRange) {
            self.path = path
            self.line = line
            self.column = column
            self.range = range
        }
    }

    /// Digit runs capped at nine and not followed by a tenth, or a long run
    /// reports a number the output never named. Anchored so `foo.rs:12` inside a
    /// URL is left to the URL detector.
    ///
    /// The path run is possessive, its last character checked by lookbehind:
    /// written as `[\w.+\-/]*[\w.+\-]+`, two overlapping quantifiers, a
    /// 100,000-character token with no colon backtracked quadratically — 54 s on
    /// the main thread per ⌘ press. `:` is in neither class, so the run can only
    /// end at the colon either way and the matches are the same.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![^\s(\[<'"])([~./]?[\w.+\-/]*+(?<=[\w.+\-])):(\d{1,9})(?!\d)(?::(\d{1,9})(?!\d))?"#,
        options: [])

    /// As in `LinkDetection`: this runs on every ⌘-hover.
    public static let maxPatternScanCells = LinkDetection.maxPatternScanCells

    public static func reference(at point: SelectionPoint, in grid: Grid) -> Reference? {
        references(inLineContaining: point.row, in: grid).references
            .first { $0.range.start <= point && point <= $0.range.end }
    }

    /// The references in the logical line holding `row`, and the row it
    /// starts on — so a caller walking a command's output can step to the
    /// line above. A line over `maxPatternScanCells` is not joined or scanned:
    /// both run on the main thread.
    public static func references(inLineContaining row: Int, in grid: Grid)
        -> (firstRow: Int, references: [Reference])
    {
        let span = grid.logicalLineRowSpan(containing: row)
        guard (span.last - span.first + 1) * grid.columns <= maxPatternScanCells else {
            return (span.first, [])
        }
        let line = grid.logicalLine(firstRow: span.first, lastRow: span.last)
        guard !line.text.isEmpty else { return (span.first, []) }
        return (span.first, references(in: line))
    }

    public static func references(in line: LogicalLine) -> [Reference] {
        let text = line.text
        let ns = text as NSString
        var found: [Reference] = []
        var cursor = CharacterOffsetCursor(text)
        pattern.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let path = ns.substring(with: match.range(at: 1))
            guard !path.isEmpty, let lineNumber = Int(ns.substring(with: match.range(at: 2))),
                lineNumber > 0
            else { return }
            // Digits and dots only is a version (`1.2.3:4`), not a file.
            guard path.contains(where: { $0.isLetter || $0 == "/" || $0 == "~" || $0 == "_" })
            else { return }
            var column: Int?
            if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                column = Int(ns.substring(with: match.range(at: 3)))
            }
            guard let startOffset = cursor.characterOffset(atUTF16Offset: match.range.location)
            else { return }
            let endOffset = startOffset + ns.substring(with: match.range).count - 1
            guard let start = line.position(at: startOffset),
                let end = line.position(at: endOffset)
            else { return }
            found.append(
                Reference(
                    path: path, line: lineNumber, column: column,
                    range: SelectionRange(
                        start: SelectionPoint(row: start.row, column: start.column),
                        end: SelectionPoint(row: end.row, column: end.column))))
        }
        return found
    }
}
