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
}
