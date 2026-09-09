import Foundation

/// U17 — `path:line:column` in program output, as a thing you can click.
///
/// Compiler errors, `grep -n`, stack traces and test failures all say where
/// they happened in the same shape, and following one means reading the path,
/// switching apps and typing it again. This finds the shape.
///
/// **This does not touch the URL scheme allowlist, and must not.**
/// `SECURITY.md` §2.4 allows exactly `http`, `https` and `mailto` to reach
/// `NSWorkspace`, and the reason is that the *text* comes from the child: a
/// `file://` or custom-scheme string in output must stay plain text. A file
/// reference is a different thing with a different rule — it is not a URL, it
/// is never parsed as one, and the app turns it into a local path only after
/// resolving it against a directory it knows to be local and confirming the
/// file exists. Adding `file` to the allowlist would have let *any* output
/// hand `NSWorkspace` an arbitrary path; this cannot, because nothing in the
/// output chooses the scheme.
///
/// **What is deliberately not detected.** A bare path with no line number.
/// Ordinary prose is full of things that look like paths (`n/a`, `and/or`,
/// `TODO/FIXME`), and a terminal that underlines a third of every sentence
/// has taught the user to ignore underlines. Requiring `:line` is what makes
/// a match mean something — it is the shape a *tool* emits, not the shape
/// English happens to have.
public enum FileReferenceDetection {
    /// One detected reference: the path exactly as it appeared, the line and
    /// optional column it named, and its span in document coordinates.
    public struct Reference: Equatable, Sendable {
        /// The path as written — relative or absolute. Resolving it is the
        /// app's job, because only the app knows the pane's directory and
        /// whether that directory is local.
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

    /// A path component, then `:` and a line number, optionally `:` and a
    /// column. The path may not contain whitespace, a colon, or the quoting
    /// characters that would mean the match had swallowed a delimiter.
    ///
    /// The digit runs are capped at nine *and* refuse to be followed by
    /// another digit: without the second half, a twenty-digit run would match
    /// its first nine and report a line number the output never named.
    ///
    /// Anchored on a non-path character (or the line start) so `foo.rs:12`
    /// inside `https://host/foo.rs:12` cannot match — a URL is the other
    /// detector's, and two detectors claiming one span would be a coin toss.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![^\s(\[<'"])([~./]?[\w.+\-/]*[\w.+\-]+):(\d{1,9})(?!\d)(?::(\d{1,9})(?!\d))?"#,
        options: [])

    /// The same bound pattern link detection uses (P08): this runs on every
    /// ⌘-hover, so an unbounded logical line must not become an unbounded
    /// regex pass on the main thread.
    public static let maxPatternScanCells = LinkDetection.maxPatternScanCells

    /// The reference under `point`, if the cell sits inside one.
    public static func reference(at point: SelectionPoint, in grid: Grid) -> Reference? {
        let span = grid.logicalLineRowSpan(containing: point.row)
        guard (span.last - span.first + 1) * grid.columns <= maxPatternScanCells
        else { return nil }
        let line = grid.logicalLine(containing: point.row)
        guard !line.text.isEmpty else { return nil }
        return references(in: line).first { $0.range.start <= point && point <= $0.range.end }
    }

    /// Every reference in one logical line, in order.
    public static func references(in line: LogicalLine) -> [Reference] {
        let text = line.text
        let ns = text as NSString
        var found: [Reference] = []
        pattern.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let path = ns.substring(with: match.range(at: 1))
            guard !path.isEmpty, let lineNumber = Int(ns.substring(with: match.range(at: 2))),
                lineNumber > 0
            else { return }
            // A path that is only digits and dots is a version number
            // (`1.2.3:4`), not a file; requiring a letter, `/`, `~` or `_`
            // somewhere is what tells the two apart.
            guard path.contains(where: { $0.isLetter || $0 == "/" || $0 == "~" || $0 == "_" })
            else { return }
            var column: Int?
            if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                column = Int(ns.substring(with: match.range(at: 3)))
            }
            let startOffset = ns.substring(to: match.range.location).count
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
