import Foundation

/// ⌘-click URL detection (M4.6).
///
/// Detection runs over logical lines (`Grid+Text.swift`), so a URL split by
/// a soft wrap is still found whole. The scheme allowlist from
/// `SECURITY.md` §2.4 is enforced here, at the pattern level: `http`,
/// `https` and `mailto` are the only schemes that can match at all — a
/// `file://` or custom-scheme string is plain text as far as the shell is
/// concerned, so no click path can ever carry it to `NSWorkspace`.
///
/// OSC 8 hyperlinks (M6.8) are checked first, because they are the case
/// where the display text and the destination can differ — the whole reason
/// "show the real target" (§2.4) is a rule. The tooltip on ⌘-hover names the
/// destination, not the text under the pointer, and the scheme allowlist is
/// applied to it at the hand-off; for a detected URL the two are the same
/// string, so the same path covers both.
public enum LinkDetection {
    /// One detected URL: its text and its span in document coordinates.
    public struct Link: Equatable, Sendable {
        public var url: String
        public var range: SelectionRange
    }

    /// The pattern: an allowlisted scheme followed by non-whitespace.
    /// Detection only — `NSWorkspace` does the final parse before opening.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://|mailto:)\S+"#, options: [.caseInsensitive])

    /// Characters that belong to the sentence, not the URL, when they
    /// appear at its end: `See https://example.com.` and parenthesised
    /// URLs like `(https://example.com)` are how URLs appear in prose.
    private static let trailingTrim: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\""]

    /// The link under `point`, if the cell sits inside one. An explicit
    /// OSC 8 hyperlink wins over pattern detection: the program said what
    /// the target is, and guessing from the text it chose to display would
    /// be guessing against the answer.
    public static func link(at point: SelectionPoint, in grid: Grid) -> Link? {
        if let explicit = hyperlink(at: point, in: grid) { return explicit }
        let line = grid.logicalLine(containing: point.row)
        guard !line.text.isEmpty else { return nil }
        return links(in: line).first { $0.range.start <= point && point <= $0.range.end }
    }

    /// The OSC 8 hyperlink the cell at `point` carries, with its range
    /// widened to the whole contiguous run of cells sharing that id on the
    /// row — which is what the hover highlight and the tooltip want.
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

    /// Every link in a logical line — exposed for tests and for a shell
    /// that wants to highlight rather than hit-test.
    public static func links(in line: LogicalLine) -> [Link] {
        let text = line.text
        let nsText = text as NSString
        var links: [Link] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            var url = match.range
            // Trim prose punctuation off the end; an unbalanced closer
            // (`)` with no opening `(` inside the URL) is prose too.
            while url.length > 0 {
                let last = Character(nsText.substring(with: NSRange(location: url.length - 1 + url.location, length: 1)))
                if trailingTrim.contains(last) {
                    url.length -= 1
                } else if last == ")" || last == "]" || last == "}" {
                    let body = nsText.substring(with: url)
                    let opener: Character = last == ")" ? "(" : last == "]" ? "[" : "{"
                    if body.filter({ $0 == opener }).count < body.filter({ $0 == last }).count {
                        url.length -= 1
                    } else { break }
                } else { break }
            }
            guard url.length > 0,
                let startOffset = offset(ofCharacterAt: url.location, in: text),
                let endOffset = offset(ofCharacterAt: url.location + url.length - 1, in: text),
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

    /// The character offset (the unit `LogicalLine.position(at:)` counts
    /// in) of the `location`-th UTF-16 unit — the regex reports UTF-16
    /// ranges, the logical line maps character offsets. Equal for ASCII,
    /// which URLs effectively always are, but a CJK prefix before the URL
    /// shifts the two apart.
    private static func offset(ofCharacterAt utf16Location: Int, in text: String) -> Int? {
        let index = String.Index(utf16Offset: utf16Location, in: text)
        return text.distance(from: text.startIndex, to: index)
    }
}
