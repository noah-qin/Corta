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
import Testing

@testable import Corta

/// `docs/CONFIGURATION.md` is the reference for the config file (D10): a key
/// without a row there is a key nobody can find. Nine `bind.` commands
/// shipped without a row before this check existed, so the table is now
/// pinned to the code that defines the keys, in both directions.
///
/// The document is read from the repository rather than a copy, located from
/// this file the way `LocalizationCoverageTests` locates the string catalog.
///
/// Every Markdown file's local links are held to the tree the same way: a
/// document that moves or disappears takes its inbound links with it.
struct DocumentationDriftTests {

    private static var configurationReference: URL {
        URL(fileURLWithPath: #filePath)  // CortaTests/DocumentationDriftTests.swift
            .deletingLastPathComponent()  // CortaTests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("docs/CONFIGURATION.md")
    }

    /// The first backticked cell of every table row, across the whole
    /// document: the settings tables use the key, the shortcut table uses
    /// the command name without its `bind.` prefix.
    private static func documentedRows(in text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("| `") else { continue }
            let cell = line.dropFirst(3)
            guard let end = cell.firstIndex(of: "`") else { continue }
            names.insert(String(cell[..<end]))
        }
        return names
    }

    /// The rows of the `### The commands` table only, for the reverse check.
    private static func documentedCommands(in text: String) -> [String] {
        var inSection = false
        var commands: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### The commands") { inSection = true; continue }
            guard inSection else { continue }
            if line.hasPrefix("#") { break }
            // The header row names the key family, not a command.
            guard line.hasPrefix("| `"), !line.hasPrefix("| `bind.` key") else { continue }
            let cell = line.dropFirst(3)
            if let end = cell.firstIndex(of: "`") { commands.append(String(cell[..<end])) }
        }
        return commands
    }

    @Test("every key the config file is written with has a row in CONFIGURATION.md")
    func everySerializedKeyIsDocumented() throws {
        let text = try String(contentsOf: Self.configurationReference, encoding: .utf8)
        let documented = Self.documentedRows(in: text)
        var missing: [String] = []
        for line in Configuration().serialized().split(separator: "\n") {
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            // Structured families (`theme.*`, `preset.*`, `bind.*`) have
            // their own sections; the shortcut table is checked below.
            guard !key.contains(".") else { continue }
            if !documented.contains(key) { missing.append(key) }
        }
        #expect(missing.isEmpty, "keys without a row: \(missing)")
    }

    @Test("every command has a row in the shortcut table, and every row is a command")
    func theShortcutTableMatchesTheCommandTable() throws {
        let text = try String(contentsOf: Self.configurationReference, encoding: .utf8)
        let rows = Self.documentedCommands(in: text)
        #expect(rows.count > 40, "the shortcut table looks truncated: \(rows.count) rows")

        let documented = Set(rows)
        let commands = Set(TerminalCommand.allCases.map(\.rawValue))
        #expect(commands.subtracting(documented).isEmpty,
                "commands without a row: \(commands.subtracting(documented).sorted())")
        #expect(documented.subtracting(commands).isEmpty,
                "rows naming no command: \(documented.subtracting(commands).sorted())")
        #expect(rows.count == documented.count, "a command is listed twice")
    }

    /// The `Default` column is what a fresh install has; the code's
    /// `defaultShortcut` is the only place that is decided.
    @Test("the shortcut table's defaults are the code's defaults")
    func theDocumentedDefaultsMatchTheCode() throws {
        let text = try String(contentsOf: Self.configurationReference, encoding: .utf8)
        var wrong: [String] = []
        for line in text.split(separator: "\n") where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 3,
                  let command = TerminalCommand(rawValue: cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")))
            else { continue }
            let documented = cells[2]
            let expected = command.defaultShortcut.map { "`\($0.text)`" } ?? "*(none"
            if !documented.hasPrefix(expected) {
                wrong.append("\(command.rawValue): documented \(documented), code \(expected)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    // MARK: - Local links

    private static var repositoryRoot: URL {
        configurationReference.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every Markdown file git would see, including new ones not yet staged,
    /// with `.gitignore` respected so build products never enter the scan.
    private static func markdownFiles() throws -> [URL] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        git.currentDirectoryURL = repositoryRoot
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0, "git ls-files failed")
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\0")
            .filter { $0.hasSuffix(".md") }
            .map { repositoryRoot.appendingPathComponent(String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals below; a typo is a test failure, not a crash path.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let fence = regex(#"^\s{0,3}(`{3,}|~{3,})"#)
    private static let inlineCode = regex(#"(`+).*?\1"#)
    private static let linkPatterns = [
        regex(#"\]\(\s*(<[^>]+>|[^\s)]+)"#),              // [text](destination)
        regex(#"^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)"#),  // [label]: destination
        regex(#"(?:src|href)\s*=\s*["']([^"']+)["']"#),    // HTML href/src
    ]

    /// Local-link candidates with their line numbers. Fenced and inline code
    /// are skipped: a link written as an example is not a link.
    static func linkDestinations(in text: String) -> [(line: Int, destination: String)] {
        var found: [(Int, String)] = []
        var openFence: String?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let whole = NSRange(raw.startIndex..., in: raw)
            if let marker = fence.firstMatch(in: raw, range: whole),
               let range = Range(marker.range(at: 1), in: raw) {
                let token = String(raw[range])
                if let open = openFence {
                    if token.first == open.first, token.count >= open.count { openFence = nil }
                } else {
                    openFence = token
                }
                continue
            }
            if openFence != nil { continue }
            let line = inlineCode.stringByReplacingMatches(in: raw, range: whole, withTemplate: "")
            let span = NSRange(line.startIndex..., in: line)
            for pattern in linkPatterns {
                for match in pattern.matches(in: line, range: span) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let destination = line[range].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    found.append((index + 1, destination))
                }
            }
        }
        return found
    }

    /// The file a destination names, or nil when it is not a local path:
    /// a remote URL, another scheme (`mailto:`, `doc:`) or a bare fragment.
    static func localTarget(of destination: String, from file: URL, root: URL) -> URL? {
        if destination.hasPrefix("//") { return nil }
        if destination.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            return nil
        }
        let path = String(destination.prefix { $0 != "?" && $0 != "#" })
        guard !path.isEmpty else { return nil }
        let target = path.removingPercentEncoding ?? path
        if target.hasPrefix("/") {
            return root.appendingPathComponent(String(target.dropFirst()))
        }
        return file.deletingLastPathComponent().appendingPathComponent(target)
    }

    /// Inline links, reference definitions and HTML `href`/`src` in every
    /// Markdown file resolve to something in the repository. Fragments,
    /// remote URLs and DocC symbol references are outside this check.
    @Test("every local link and asset in the Markdown files exists")
    func everyLocalLinkResolves() throws {
        let root = Self.repositoryRoot
        let files = try Self.markdownFiles()
        #expect(files.count > 20, "the Markdown scan looks empty: \(files.count) files")
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, destination) in Self.linkDestinations(in: text) {
                guard let target = Self.localTarget(of: destination, from: file, root: root) else { continue }
                if !FileManager.default.fileExists(atPath: target.path) {
                    let name = file.path.replacingOccurrences(of: root.path + "/", with: "")
                    missing.append("\(name):\(line): missing target: \(destination)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }

    @Test("links in code are not links, and only local paths are checked")
    func theLinkScannerSkipsWhatItShould() {
        let text = """
            [a](docs/A.md) `[b](B.md)`
            ```
            [c](C.md)
            ```
            [ref]: <docs/D%20E.md#part>
            <img src="assets/f.png">
            """
        #expect(Self.linkDestinations(in: text).map(\.destination)
                == ["docs/A.md", "docs/D%20E.md#part", "assets/f.png"])
        let root = URL(fileURLWithPath: "/repo")
        let file = root.appendingPathComponent("docs/X.md")
        #expect(Self.localTarget(of: "https://example.com", from: file, root: root) == nil)
        #expect(Self.localTarget(of: "doc:Terminal", from: file, root: root) == nil)
        #expect(Self.localTarget(of: "#section", from: file, root: root) == nil)
        #expect(Self.localTarget(of: "D%20E.md#part", from: file, root: root)?.path == "/repo/docs/D E.md")
        #expect(Self.localTarget(of: "/README.md", from: file, root: root)?.path == "/repo/README.md")
    }
}
