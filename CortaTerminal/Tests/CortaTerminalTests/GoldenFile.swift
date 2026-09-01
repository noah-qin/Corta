import Foundation
import Testing

@testable import CortaTerminal

/// M1.6 — the golden-file harness (`CONFORMANCE.md` §4.1).
///
/// A case is two files in `Golden/`:
///
/// - `<name>.in` — the byte stream, escape-encoded (see `decode`).
/// - `<name>.txt` — the expected grid dump, **written by hand**.
///
/// Set `CORTA_UPDATE_GOLDEN=1` to rewrite the `.txt` files from the current
/// implementation. That switch is for propagating a deliberate format change,
/// never for authoring an expectation: an expectation generated from the code
/// under test asserts only that the code did what it did.
enum Golden {
    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let rows: Int
        let columns: Int

        init(_ name: String, rows: Int = 24, columns: Int = 80) {
            self.name = name
            self.rows = rows
            self.columns = columns
        }

        var description: String { name }
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Golden")
    }

    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment["CORTA_UPDATE_GOLDEN"] == "1"
    }

    /// Feeds a case's input to a fresh terminal and returns it.
    static func run(_ testCase: Case) throws -> Terminal {
        let url = directory.appendingPathComponent("\(testCase.name).in")
        let source = try String(contentsOf: url, encoding: .utf8)
        var terminal = Terminal(rows: testCase.rows, columns: testCase.columns)
        terminal.feed(try decode(source))
        return terminal
    }

    /// Runs a case and compares its dump against the checked-in expectation.
    static func verify(
        _ testCase: Case,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try run(testCase).dump()
        let url = directory.appendingPathComponent("\(testCase.name).txt")

        if isUpdating {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(
            actual == expected,
            "\(testCase.name)\n\(diff(expected: expected, actual: actual))",
            sourceLocation: sourceLocation
        )
    }

    /// A line-oriented diff. The grid dump is a fixed-width block, so
    /// aligning the two sides by line number is enough to point at the row
    /// and column that moved.
    static func diff(expected: String, actual: String) -> String {
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        var report = ""
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let left = index < expectedLines.count ? String(expectedLines[index]) : nil
            let right = index < actualLines.count ? String(actualLines[index]) : nil
            guard left != right else { continue }
            report += "line \(index + 1):\n"
            report += "  expected: \(left.map { "\"\($0)\"" } ?? "(missing)")\n"
            report += "    actual: \(right.map { "\"\($0)\"" } ?? "(missing)")\n"
        }
        return report.isEmpty ? "(identical)" : report
    }

    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    /// Decodes an input file into bytes.
    ///
    /// Literal newlines are formatting and are **ignored**, so a byte stream
    /// can be laid out over several lines and reviewed in a diff; a newline
    /// in the stream is written `\n`. Lines beginning with `#` are comments —
    /// every case cites the behaviour it anchors.
    ///
    /// Escapes: `\e` ESC, `\a` BEL, `\b` BS, `\t` HT, `\n` LF, `\r` CR,
    /// `\f` FF, `\v` VT, `\0` NUL, `\xNN` any byte, `\\` backslash.
    static func decode(_ source: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { continue }
            var characters = Array(line.utf8)
            var index = 0
            while index < characters.count {
                let byte = characters[index]
                guard byte == UInt8(ascii: "\\") else {
                    bytes.append(byte)
                    index += 1
                    continue
                }
                index += 1
                guard index < characters.count else {
                    throw DecodeError(description: "trailing backslash in \"\(line)\"")
                }
                let escape = characters[index]
                index += 1
                switch escape {
                case UInt8(ascii: "e"): bytes.append(0x1B)
                case UInt8(ascii: "a"): bytes.append(0x07)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "v"): bytes.append(0x0B)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "0"): bytes.append(0x00)
                case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "x"):
                    guard index + 1 < characters.count,
                        let value = UInt8(
                            String(decoding: characters[index...(index + 1)], as: UTF8.self),
                            radix: 16
                        )
                    else {
                        throw DecodeError(description: "bad \\x escape in \"\(line)\"")
                    }
                    bytes.append(value)
                    index += 2
                default:
                    throw DecodeError(
                        description: "unknown escape \\\(Character(UnicodeScalar(escape))) in \"\(line)\""
                    )
                }
            }
            characters.removeAll()
        }
        return bytes
    }
}
