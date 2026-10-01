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

import Testing

@testable import CortaTerminal

/// A column change re-wraps the document (D03); what OSC 133 attached to its
/// rows, and what refers to them by absolute row, must come through with it.
@Suite("Reflow keeps marks and records")
struct ReflowMarksTests {
    /// `count` commands, each a prompt, a command line and one output line;
    /// every third fails.
    private static func commands(_ count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for index in 0..<count {
            let status = index % 3 == 2 ? 1 : 0
            bytes += Array(
                "\u{1B}]133;A\u{1B}\\$ cmd\(index)\r\n\u{1B}]133;C\u{1B}\\out \(index)\r\n\u{1B}]133;D;\(status)\u{1B}\\"
                    .utf8)
        }
        return bytes + Array("\u{1B}]133;A\u{1B}\\$ ".utf8)
    }

    /// The text of the row `absolute` names, trailing blanks trimmed.
    private static func text(_ terminal: Terminal, atAbsoluteRow absolute: Int) -> String? {
        let grid = terminal.grid
        let row = absolute - grid.scrollback.totalPushed
        guard grid.line(atAbsoluteRow: absolute) != nil else { return nil }
        return grid.documentLine(row).cells.map {
            String(Character(Unicode.Scalar($0.scalar) ?? " "))
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    @Test("prompt and status marks survive widening and narrowing")
    func marksSurviveAColumnChange() {
        var terminal = Terminal(rows: 5, columns: 20, scrollbackLimit: 100)
        terminal.feed(Self.commands(12))
        let prompts = terminal.grid.promptRows.count
        let failed = terminal.grid.failedPromptRows.count
        let outputs = terminal.grid.outputStartRows.count
        #expect(prompts == 13)
        #expect(failed == 4)

        for columns in [30, 7, 20] {
            terminal.resize(rows: 5, columns: columns)
            #expect(terminal.grid.promptRows.count == prompts, "at \(columns) columns")
            #expect(terminal.grid.failedPromptRows.count == failed, "at \(columns) columns")
            #expect(terminal.grid.outputStartRows.count == outputs, "at \(columns) columns")
        }
    }

    @Test("totalPushed never runs backwards through a reflow")
    func totalPushedOnlyGrows() {
        var terminal = Terminal(rows: 5, columns: 20, scrollbackLimit: 1_000)
        for index in 0..<300 { terminal.feed(Array("line \(index)\r\n".utf8)) }
        var last = terminal.grid.scrollback.totalPushed
        #expect(last == 296)
        for columns in [30, 8, 40, 20] {
            terminal.resize(rows: 5, columns: columns)
            #expect(terminal.grid.scrollback.totalPushed >= last, "at \(columns) columns")
            last = terminal.grid.scrollback.totalPushed
        }
    }

    @Test("command records and the open prompt point at their own rows after a reflow")
    func recordsFollowTheirRows() throws {
        var terminal = Terminal(rows: 5, columns: 20, scrollbackLimit: 100)
        terminal.feed(Self.commands(12))
        for columns in [30, 6, 20] {
            terminal.resize(rows: 5, columns: columns)
            // The open prompt (the last record) has no command or output yet.
            for record in terminal.commandRecords.records where !record.isRunning {
                let index = record.id
                // At 6 columns "$ cmdN" wraps; its first row is all the row holds.
                let prefix = String("$ cmd\(index)".prefix(columns))
                #expect(
                    Self.text(terminal, atAbsoluteRow: record.promptRow)?.hasPrefix(prefix) == true,
                    "record \(index) at \(columns) columns")
                let output = try #require(record.outputStartRow)
                #expect(
                    Self.text(terminal, atAbsoluteRow: output)?.hasPrefix("out") == true,
                    "record \(index)'s output at \(columns) columns")
                #expect(
                    terminal.grid.line(atAbsoluteRow: record.promptRow)?.mark.isPrompt == true,
                    "record \(index)'s row carries its prompt mark at \(columns) columns")
            }
        }
    }

    @Test("leaving the alternate screen after a width change keeps the records on their rows")
    func alternateScreenExitReflowKeepsRecords() throws {
        var terminal = Terminal(rows: 5, columns: 20, scrollbackLimit: 100)
        terminal.feed(Self.commands(6))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.resize(rows: 5, columns: 4)  // "$ cmd5" and "out 5" both wrap
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        let last = try #require(terminal.commandRecords.lastCompleted)
        #expect(terminal.grid.line(atAbsoluteRow: last.promptRow)?.mark.isPrompt == true)
        #expect(Self.text(terminal, atAbsoluteRow: try #require(last.outputStartRow))?.hasPrefix("out") == true)
    }
}
