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

/// The repository's license-header rules, as data and pure functions:
/// which files carry the Apache-2.0 notice in the file itself, which are
/// covered by `REUSE.toml` instead, and what exactly a correct header is.
/// `corta-license` is the command-line front; `docs/LICENSING.md` is the
/// reference a person reads.
///
/// Everything here works on a path and the file's text, never on the file
/// system, so every rule is testable without a checkout.
public enum LicenseHeaders {
    /// How a file is licensed.
    public enum Treatment: Equatable, Sendable {
        /// The notice lives in the file, in this comment syntax.
        case header(CommentStyle)
        /// The file cannot carry a comment, or must not (a test input);
        /// `REUSE.toml` states its license.
        case reuse
        /// A license text itself, which is not licensed by a notice.
        case excluded
    }

    public enum CommentStyle: Equatable, Sendable {
        /// `//` — Swift and Metal.
        case slashes
        /// `#` — shell, Python, YAML, TOML and the dotfiles.
        case hash

        var marker: String { self == .slashes ? "//" : "#" }
    }

    /// The copyright holder named on the first line of every header.
    public static let holder = "Noah Qin"

    /// The first year a header may name. A file's year is the year it was
    /// created; nothing in this repository predates this one.
    public static let firstYear = 2026

    /// Ordered rules: the first pattern that matches a path decides it. A
    /// path no rule matches is an error, not a pass — a new kind of file
    /// has to be classified on purpose. Patterns are globs over the path
    /// relative to the repository root: `*` stays within a directory, `**`
    /// crosses them.
    public static let rules: [(pattern: String, treatment: Treatment)] = [
        // License texts.
        ("LICENSE", .excluded),
        ("LICENSES/**", .excluded),

        // Files that must not change by a byte, or cannot hold a comment.
        ("CortaTerminal/Tests/CortaTerminalTests/Golden/**", .reuse),
        ("CortaTerminal/Tests/Fuzz/**", .reuse),
        ("CortaTests/RenderReferences/**", .reuse),
        ("docs/esctest/**", .reuse),
        ("docs/brand/*.png", .reuse),
        ("docs/brand/*.gif", .reuse),
        ("docs/test-results/issue-228-*.png", .reuse),
        ("docs/test-results/memory-core-2026-10-11/*.png", .reuse),
        ("docs/test-results/memory-core-2026-10-11/raw-benchmarks.txt", .reuse),
        ("AppIcon.icon/**", .reuse),
        ("AppIconDev.icon/**", .reuse),
        ("Corta/Acknowledgements/**", .reuse),
        ("Corta.xcodeproj/**", .reuse),
        ("Corta/Assets.xcassets/**", .reuse),
        ("Corta/Localizable.xcstrings", .reuse),
        ("TestPlans/*.xctestplan", .reuse),
        ("Sparkle-Info.plist", .reuse),
        ("Corta/PrivacyInfo.xcprivacy", .reuse),
        ("appcast.xml", .reuse),
        ("**/*.md", .reuse),
        ("NOTICE", .reuse),

        // Source.
        ("**/*.swift", .header(.slashes)),
        ("**/*.metal", .header(.slashes)),
        ("**/*.sh", .header(.hash)),
        ("**/*.py", .header(.hash)),
        ("**/*.yml", .header(.hash)),
        ("**/*.yaml", .header(.hash)),
        ("**/*.toml", .header(.hash)),
        (".gitignore", .header(.hash)),
        (".github/CODEOWNERS", .header(.hash)),
    ]

    /// How `path` is licensed, or `nil` when no rule knows it.
    public static func treatment(for path: String) -> Treatment? {
        rules.first { Glob.matches($0.pattern, path) }?.treatment
    }

    // MARK: - The header

    /// The Apache License's own appendix boilerplate, line for line —
    /// including its `http://` URL — between the copyright line and the
    /// SPDX identifier.
    static let body = [
        "Licensed under the Apache License, Version 2.0 (the \"License\");",
        "you may not use this file except in compliance with the License.",
        "You may obtain a copy of the License at",
        "",
        "    http://www.apache.org/licenses/LICENSE-2.0",
        "",
        "Unless required by applicable law or agreed to in writing, software",
        "distributed under the License is distributed on an \"AS IS\" BASIS,",
        "WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.",
        "See the License for the specific language governing permissions and",
        "limitations under the License.",
    ]

    // REUSE-IgnoreStart — a string about the tag, not a license declaration.
    static let spdx = "SPDX-License-Identifier: Apache-2.0"
    // REUSE-IgnoreEnd

    /// The header for `year`, one element per line, in `style`'s syntax.
    /// An empty line of the text is the bare marker, with no trailing
    /// space.
    public static func header(year: Int, style: CommentStyle) -> [String] {
        let text = ["Copyright \(year) \(holder)", ""] + body + ["", spdx]
        return text.map { $0.isEmpty ? style.marker : "\(style.marker) \($0)" }
    }

    // MARK: - Checking

    public enum Finding: Equatable, Sendable {
        /// No header where one belongs.
        case missing
        /// Something that looks like a header is there but is not the
        /// standard text — altered, reordered, or with a year range. Not
        /// repaired automatically: whatever is there was put there by hand.
        case malformed(String)
    }

    /// Whether `text`, the contents of a file licensed in `style`, carries
    /// the standard header in the right place. `nil` means it does.
    /// `currentYear` bounds the year a header may name.
    public static func check(_ text: String, style: CommentStyle, currentYear: Int) -> Finding? {
        let lines = text.components(separatedBy: "\n")
        let start = preludeLength(lines, style: style)
        let expected = header(year: 0, style: style)
        guard lines.count >= start + expected.count,
            let year = copyrightYear(lines[start], style: style)
        else {
            return looksLikeHeader(lines)
                ? .malformed("the header does not open with `\(style.marker) Copyright <year> \(holder)`")
                : .missing
        }
        guard (firstYear...currentYear).contains(year) else {
            return .malformed("year \(year) is outside \(firstYear)–\(currentYear)")
        }
        for (offset, want) in expected.enumerated().dropFirst()
        where lines[start + offset] != want {
            return .malformed("line \(start + offset + 1) is `\(lines[start + offset])`, expected `\(want)`")
        }
        let after = start + expected.count
        if after < lines.count, !lines[after].isEmpty {
            return .malformed("line \(after + 1) must be blank after the header")
        }
        return nil
    }

    /// Lines that must stay above the header: a shebang, which the kernel
    /// reads from the first two bytes, and SwiftPM's
    /// `// swift-tools-version`, which must be the manifest's first line.
    static func preludeLength(_ lines: [String], style: CommentStyle) -> Int {
        guard let first = lines.first else { return 0 }
        switch style {
        case .hash: return first.hasPrefix("#!") ? 1 : 0
        case .slashes: return first.hasPrefix("// swift-tools-version") ? 1 : 0
        }
    }

    /// The year on a copyright line, when the line is exactly one; a range
    /// (`2026-2027`) or any other decoration is not.
    static func copyrightYear(_ line: String, style: CommentStyle) -> Int? {
        let prefix = "\(style.marker) Copyright "
        let suffix = " \(holder)"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let year = line.dropFirst(prefix.count).dropLast(suffix.count)
        guard year.count == 4, year.allSatisfy(\.isASCII), year.allSatisfy(\.isNumber) else { return nil }
        return Int(year)
    }

    static func looksLikeHeader(_ lines: [String]) -> Bool {
        // REUSE-IgnoreStart
        lines.prefix(40).contains { $0.contains("SPDX-License-Identifier") || $0.contains("Licensed under the Apache") }
        // REUSE-IgnoreEnd
    }

    // MARK: - Fixing

    /// `text` with the standard header added for `year`, or `nil` when
    /// nothing should change: the header is already correct, or something
    /// header-like is there that a person has to look at (`check` says
    /// what). An Xcode "Created by" template header is replaced, not kept
    /// beside the new one.
    public static func fixed(_ text: String, style: CommentStyle, year: Int, currentYear: Int) -> String? {
        guard check(text, style: style, currentYear: currentYear) == .missing else { return nil }
        var lines = text.components(separatedBy: "\n")
        let start = preludeLength(lines, style: style)
        var rest = Array(lines[start...])
        if style == .slashes { rest = droppingXcodeTemplate(rest) }
        while let first = rest.first, first.isEmpty, rest.count > 1 { rest.removeFirst() }
        let prelude = Array(lines[..<start])
        let body = rest == [""] ? [""] : [""] + rest
        lines = prelude + header(year: year, style: style) + body
        return lines.joined(separator: "\n")
    }

    /// Removes a leading Xcode file template — a `//` block naming the file
    /// and "Created by" someone — which says nothing the repository does
    /// not already record.
    static func droppingXcodeTemplate(_ lines: [String]) -> [String] {
        var end = 0
        while end < lines.count, lines[end].hasPrefix("//") { end += 1 }
        guard end > 0, lines[..<end].contains(where: { $0.hasPrefix("//  Created by ") }) else { return lines }
        return Array(lines[end...])
    }
}

/// Glob matching over `/`-separated relative paths: `*` matches within one
/// path component, `**` any number of them, `?` one character.
enum Glob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        match(Array(pattern.unicodeScalars), 0, Array(path.unicodeScalars), 0)
    }

    private static func match(_ p: [Unicode.Scalar], _ i: Int, _ s: [Unicode.Scalar], _ j: Int) -> Bool {
        if i == p.count { return j == s.count }
        if p[i] == "*", i + 1 < p.count, p[i + 1] == "*" {
            // `**/` may match nothing at all; `**` may match across `/`.
            let next = i + 2 < p.count && p[i + 2] == "/" ? i + 3 : i + 2
            if next != i + 2, match(p, next, s, j) { return true }
            var k = j
            while k <= s.count {
                if match(p, next, s, k) { return true }
                k += 1
            }
            return false
        }
        if p[i] == "*" {
            var k = j
            while k <= s.count {
                if match(p, i + 1, s, k) { return true }
                if k == s.count || s[k] == "/" { break }
                k += 1
            }
            return false
        }
        guard j < s.count else { return false }
        if p[i] == "?" { return s[j] != "/" && match(p, i + 1, s, j + 1) }
        return p[i] == s[j] && match(p, i + 1, s, j + 1)
    }
}
