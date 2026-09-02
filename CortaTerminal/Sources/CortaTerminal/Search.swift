/// Scrollback search (M4.4).
///
/// Matching is over logical lines (`Grid+Text.swift`), not rows, so a match
/// spanning a soft wrap is found whole. Case-insensitive by default. Reuses
/// `SelectionRange`/`SelectionPoint` (`Selection.swift`) for a match's span:
/// same document-row numbering, same highlighting a caller already knows
/// how to turn into a selection-shaped overlay.
///
/// Iterates via `Grid.logicalLines()`, which never materializes the whole
/// scrollback into one array (`PERFORMANCE.md` §4) — a search over a full
/// 100k-line scrollback is one lazy pass, not a copy.
public enum Search {
    /// Every match of `query` in the document, oldest first. Empty for an
    /// empty query rather than matching every position.
    public static func find(_ query: String, in grid: Grid, caseSensitive: Bool = false) -> [SelectionRange] {
        guard !query.isEmpty else { return [] }
        var results: [SelectionRange] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        for logicalLine in grid.logicalLines() {
            let text = logicalLine.text
            guard !text.isEmpty else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                let found = text.range(of: query, options: options, range: searchStart..<text.endIndex)
            {
                guard !found.isEmpty else { break }
                let startOffset = text.distance(from: text.startIndex, to: found.lowerBound)
                let endOffset = text.distance(from: text.startIndex, to: found.upperBound) - 1
                if let startPosition = logicalLine.position(at: startOffset),
                    let endPosition = logicalLine.position(at: endOffset)
                {
                    results.append(
                        SelectionRange(
                            start: SelectionPoint(row: startPosition.row, column: startPosition.column),
                            end: SelectionPoint(row: endPosition.row, column: endPosition.column)))
                }
                searchStart = found.upperBound
            }
        }
        return results
    }
}
