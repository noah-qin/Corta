import Testing

@testable import CortaTerminal

/// M4.6 — URL detection over logical lines: the scheme allowlist, prose
/// punctuation trimming, soft-wrap joining and hit-testing by cell.
@Suite("LinkDetection")
struct LinkDetectionTests {
    private func terminal(columns: Int = 40, feeding text: String) -> Terminal {
        var terminal = Terminal(rows: 5, columns: columns)
        terminal.feed(Array(text.utf8))
        return terminal
    }

    @Test("an https URL is found with its exact span")
    func plainURL() {
        let terminal = self.terminal(feeding: "see https://example.com/x now")
        let grid = terminal.grid
        let link = LinkDetection.link(at: SelectionPoint(row: 0, column: 10), in: grid)
        #expect(link?.url == "https://example.com/x")
        #expect(link?.range.start == SelectionPoint(row: 0, column: 4))
        #expect(link?.range.end == SelectionPoint(row: 0, column: 4 + 21 - 1))
    }

    @Test("only http, https and mailto can match")
    func schemeAllowlist() {
        let terminal = self.terminal(feeding: "file:///etc/passwd and ftp://x.y")
        let grid = terminal.grid
        // file:// at column 0, ftp:// at column 25 — neither may detect.
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 2), in: grid) == nil)
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 27), in: grid) == nil)

        let mail = self.terminal(feeding: "mailto:a@b.c")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 3), in: mail.grid)?.url
                == "mailto:a@b.c")
    }

    @Test("sentence punctuation is not part of the URL")
    func trailingPunctuation() {
        let terminal = self.terminal(feeding: "see https://example.com/a.")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 5), in: terminal.grid)?.url
                == "https://example.com/a")
    }

    @Test("an unbalanced closing paren is prose, a balanced one is content")
    func parenBalance() {
        let prose = self.terminal(feeding: "(see https://example.com/a)")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 6), in: prose.grid)?.url
                == "https://example.com/a")
        let wiki = self.terminal(feeding: "https://x.y/Foo_(bar)")
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 0, column: 2), in: wiki.grid)?.url
                == "https://x.y/Foo_(bar)")
    }

    @Test("a URL split by a soft wrap is found whole")
    func softWrappedURL() {
        // The URL starts at column 32 of 40 and wraps mid-token.
        let terminal = self.terminal(feeding: String(repeating: "x", count: 32) + "https://example.com/long")
        let grid = terminal.grid
        let link = LinkDetection.link(at: SelectionPoint(row: 1, column: 3), in: grid)
        #expect(link?.url == "https://example.com/long")
        #expect(link?.range.start == SelectionPoint(row: 0, column: 32))
        #expect(link?.range.end == SelectionPoint(row: 1, column: 32 + 24 - 40 - 1))
    }

    @Test("a click outside any URL finds nothing")
    func misses() {
        let terminal = self.terminal(feeding: "see https://example.com now")
        #expect(LinkDetection.link(at: SelectionPoint(row: 0, column: 0), in: terminal.grid) == nil)
        #expect(LinkDetection.link(at: SelectionPoint(row: 1, column: 0), in: terminal.grid) == nil)
    }

    // P08 — the hover path is bounded: pattern detection skips logical
    // lines past `maxPatternScanCells`.

    /// One wrapped line of ~120k cells — past the cap — with a URL in the
    /// middle of it. The screen is tall enough that nothing scrolls, so a
    /// cell's document row is its flat offset ÷ 120: the URL starts at
    /// cell 60_000, i.e. row 500.
    private func hugeLineTerminal(feeding payload: String) -> Terminal {
        var terminal = Terminal(rows: 1_100, columns: 120)
        terminal.feed(Array(payload.utf8))
        return terminal
    }

    @Test("a logical line past the scan cap detects no pattern links")
    func beyondCapDetectsNothing() {
        let terminal = hugeLineTerminal(
            feeding: String(repeating: "x", count: 60_000) + "https://example.com/"
                + String(repeating: "y", count: 60_000))
        // Inside the URL run — no link, because the whole chain is skipped.
        #expect(
            LinkDetection.link(at: SelectionPoint(row: 500, column: 5), in: terminal.grid) == nil)
    }

    @Test("an OSC 8 hyperlink past the scan cap still resolves")
    func explicitLinkSurvivesTheCap() {
        let terminal = hugeLineTerminal(
            feeding: String(repeating: "x", count: 60_000)
                + "\u{1B}]8;;https://example.com\u{1B}\\click\u{1B}]8;;\u{1B}\\"
                + String(repeating: "y", count: 60_000))
        let link = LinkDetection.link(at: SelectionPoint(row: 500, column: 1), in: terminal.grid)
        #expect(link?.url == "https://example.com")
    }
}

/// U17 — `path:line:column` in output. The shape a *tool* emits, which is
/// what makes a match mean something; a bare path is deliberately not
/// detected, because ordinary prose is full of things that look like one.
@Suite struct FileReferenceDetectionTests {
    private static func line(_ text: String, columns: Int = 200) -> LogicalLine {
        var terminal = Terminal(rows: 4, columns: columns, scrollbackLimit: 10)
        terminal.feed(Array(text.utf8))
        return terminal.grid.logicalLine(containing: 0)
    }

    @Test("the shapes tools actually emit")
    func realWorldShapes() {
        let cases: [(String, String, Int, Int?)] = [
            ("src/main.rs:42:17: error: no", "src/main.rs", 42, 17),
            ("Corta/ViewController.swift:1209", "Corta/ViewController.swift", 1209, nil),
            ("/usr/include/stdio.h:100:", "/usr/include/stdio.h", 100, nil),
            ("./build.sh:7: syntax", "./build.sh", 7, nil),
            ("~/notes.md:3", "~/notes.md", 3, nil),
            ("Makefile:12: warning", "Makefile", 12, nil),
        ]
        for (text, path, number, column) in cases {
            let found = FileReferenceDetection.references(in: Self.line(text))
            #expect(found.count == 1, "\(text)")
            #expect(found.first?.path == path, "\(text)")
            #expect(found.first?.line == number, "\(text)")
            #expect(found.first?.column == column, "\(text)")
        }
    }

    /// A bare path is not a reference. Underlining a third of every sentence
    /// teaches the user to ignore underlines.
    @Test("a path without a line number is not a reference")
    func barePathsAreNotDetected() {
        for text in ["see src/main.rs for", "and/or", "n/a", "TODO/FIXME", "/usr/local/bin"] {
            #expect(FileReferenceDetection.references(in: Self.line(text)).isEmpty, "\(text)")
        }
    }

    /// A version number is digits and dots with a colon after it, and is not
    /// a file.
    @Test("a version number is not a reference")
    func versionNumbers() {
        #expect(FileReferenceDetection.references(in: Self.line("1.2.3:4")).isEmpty)
    }

    /// URLs belong to the other detector. Two detectors claiming one span
    /// would be a coin toss, so this one does not start inside a URL.
    @Test("a URL is not mistaken for a file reference")
    func urlsAreNotReferences() {
        let found = FileReferenceDetection.references(in: Self.line("https://example.com/a.rs:12"))
        #expect(found.isEmpty)
    }

    @Test("several references on one line are all found")
    func multiplePerLine() {
        let found = FileReferenceDetection.references(in: Self.line("a/b.c:1 and d/e.f:2:3"))
        #expect(found.count == 2)
        #expect(found.first?.path == "a/b.c")
        #expect(found.last?.column == 3)
    }

    @Test("the span covers the whole reference")
    func spanCoversTheMatch() {
        let found = FileReferenceDetection.references(in: Self.line("x src/a.rs:9:2 y"))
        let reference = try! #require(found.first)
        #expect(reference.range.start.column == 2)
        #expect(reference.range.end.column == 2 + "src/a.rs:9:2".count - 1)
    }

    /// A line number of zero is not a line, and a nine-digit cap keeps a
    /// pathological run of digits from being parsed at all.
    @Test("implausible line numbers are refused")
    func implausibleNumbers() {
        #expect(FileReferenceDetection.references(in: Self.line("a.rs:0")).isEmpty)
        #expect(
            FileReferenceDetection.references(in: Self.line("a.rs:12345678901234567890")).isEmpty)
    }
}
