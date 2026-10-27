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

import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// Real interactive shells, isolated from the user's startup files. The PTY
/// output goes through Corta's parser, so both history and result marks count.
@MainActor
struct ShellIntegrationSessionTests {
    @Test("empty Return never completes a command", arguments: [
        "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
    ])
    func emptyReturn(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            try #require(shell.hasSuffix("fish"), "system shell missing: \(shell)")
            return
        }
        try exercise(shell: shell, fishFallback: false)
        if shell.hasSuffix("fish") {
            try exercise(shell: shell, fishFallback: true)
        }
    }

    @Test func blankZshTabInsertsFourSpacesAndCommandTabStillCompletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corta-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zshrcScript = "PROMPT='demo> '\n" + ShellIntegrationScript.script(for: .zsh)
        try zshrcScript.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "".write(
            to: directory.appendingPathComponent("unique-completion-target"), atomically: true, encoding: .utf8)
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-d", "-i"],
            environment: [
                "HOME": directory.path, "ZDOTDIR": directory.path, "TERM": "xterm-256color", "TERM_PROGRAM": "Corta",
                "LC_ALL": "C", "PATH": "/usr/bin:/bin",
            ],
            size: TerminalSize(rows: 20, columns: 100), workingDirectory: directory.path)
        defer { session.stop() }
        session.start()
        func waitFor(_ condition: (Grid) -> Bool) throws {
            let deadline = SuspendingClock.now + .seconds(5) * testTimeoutScale
            while SuspendingClock.now < deadline {
                if condition(session.snapshot()) { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(Bool(false), "\(session.snapshot().dump())")
        }
        try waitFor { $0.cursor.column == 6 && $0.dump().contains("demo>") }
        session.write([0x09])
        try waitFor { $0.cursor.column == 10 }
        session.write([0x09])
        try waitFor { $0.cursor.column == 14 }
        session.write([0x15]) // Ctrl-U clears the indentation.
        session.write(Array("cat unique-".utf8))
        session.write([0x09])
        try waitFor { $0.dump().contains("cat unique-completion-target") }
    }

    private func exercise(shell: String, fishFallback: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-shell-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "CORTA-READY> "
        let session = try Self.makeSession(shell: shell, fishFallback: fishFallback, in: directory, prompt: prompt)
        defer { session.stop() }
        session.start()

        func waitForPrompt(after row: Int) throws {
            let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
            while SuspendingClock.now < deadline {
                if let record = session.commandRecords.last,
                   record.promptRow > row, record.promptEndColumn == prompt.count {
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(
                Bool(false), "\(shell), fallback=\(fishFallback): prompt timed out\n\(session.snapshot().dump())")
        }
        func expectResults(_ statuses: [Int]) {
            let records = session.commandRecords.records
            #expect(records.compactMap(\.exitStatus) == statuses)
            // Exactly the completed commands plus the live prompt record.
            #expect(records.count == statuses.count + 1)
            let grid = session.snapshot()
            let marks = grid.promptRows.compactMap { grid.line(atAbsoluteRow: $0)?.mark }
            #expect(marks.filter { $0 == .promptSucceeded }.count == statuses.filter { $0 == 0 }.count)
            #expect(marks.filter { $0 == .promptFailed }.count == statuses.filter { $0 != 0 }.count)
        }
        try waitForPrompt(after: -1)
        expectResults([])
        let steps: [(String, [Int])] = [
            ("", []), ("", []), ("true", [0]), ("", [0]),
            ("false", [0, 1]), ("", [0, 1]), ("", [0, 1]),
        ]
        for (command, statuses) in steps {
            let previous = try #require(session.commandRecords.last).promptRow
            session.write(Array((command + "\n").utf8))
            try waitForPrompt(after: previous)
            expectResults(statuses)
        }

        // Real line editors must continue editing after the app relocates
        // their display. Return below is an explicit test keystroke, never
        // part of Clear Screen, and only executes these fixture commands.
        for input in ["", "printf '%s\\n' abcd"] {
            try Self.checkClearScreen(
                typing: input, in: session, shell: shell, waitForPrompt: waitForPrompt(after:))
        }
    }

    /// `shell`, interactive, reading only the integration script after a
    /// prompt that prints `prompt`, at home in `directory`; not started.
    private static func makeSession(
        shell: String, fishFallback: Bool, in directory: URL, prompt: String
    ) throws -> TerminalSession {
        var environment = [
            "HOME": directory.path, "ZDOTDIR": directory.path,
            "XDG_CONFIG_HOME": directory.path, "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LC_ALL": "C",
        ]
        let script: String
        let arguments: [String]
        if shell.hasSuffix("zsh") {
            script = "PS1='\(prompt)'\n" + ShellIntegrationScript.zsh
            let zshrcURL = directory.appendingPathComponent(".zshrc")
            try script.write(to: zshrcURL, atomically: true, encoding: .utf8)
            arguments = ["-d", "-i"]
        } else if shell.hasSuffix("bash") {
            script = "PS1='\(prompt)'\n" + ShellIntegrationScript.bash
            let bashrcURL = directory.appendingPathComponent("bashrc")
            try script.write(to: bashrcURL, atomically: true, encoding: .utf8)
            arguments = ["--noprofile", "--rcfile", bashrcURL.path, "-i"]
        } else {
            if fishFallback { environment["fish_features"] = "no-mark-prompt" }
            script = "function fish_prompt; printf '\(prompt)'; end\n" + ShellIntegrationScript.fish
            let fishConfigURL = directory.appendingPathComponent("init.fish")
            try script.write(to: fishConfigURL, atomically: true, encoding: .utf8)
            arguments = ["--no-config", "-i", "-C", "source " + fishConfigURL.path]
        }
        return try TerminalSession(
            executable: shell, arguments: arguments, environment: environment,
            size: TerminalSize(rows: 40, columns: 120), workingDirectory: directory.path)
    }

    /// Clear Screen with `input` typed and the cursor moved into it keeps
    /// the editor's line, cursor and records, and the edit still runs.
    private static func checkClearScreen(
        typing input: String, in session: TerminalSession, shell: String,
        waitForPrompt: (Int) throws -> Void
    ) throws {
        let start = session.snapshot()
        session.write(Array(input.utf8))
        let end = SuspendingClock.now + .seconds(5) * testTimeoutScale
        let expectedColumn = start.cursor.column + input.count
        while session.snapshot().cursor.column != expectedColumn && SuspendingClock.now < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(session.snapshot().cursor.column == expectedColumn)
        if !input.isEmpty {
            session.write(Array("\u{1B}[D\u{1B}[D".utf8))
            while session.snapshot().cursor.column != expectedColumn - 2 && SuspendingClock.now < end {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(session.snapshot().cursor.column == expectedColumn - 2)
        }
        let before = session.snapshot()
        let promptRow = try #require(session.commandRecords.last).promptRow
        let screenRow = try #require(before.screenRow(ofAbsoluteRow: promptRow))
        let records = session.commandRecords.records.count
        session.apply(.clearScreen)
        let cleared = session.snapshot()
        #expect(cleared.line(0) == before.line(screenRow))
        #expect(cleared.cursor.row == before.cursor.row - screenRow)
        #expect(cleared.cursor.column == before.cursor.column)
        #expect(session.commandRecords.records.count == records)
        #expect(!session.isCommandRunning)
        if input.isEmpty {
            session.write(Array("printf '%s\\n' empty-clear-ok\r".utf8))
        } else {
            session.write(Array("X\r".utf8))
        }
        try waitForPrompt(cleared.absoluteRow(ofScreenRow: 0))
        let output = input.isEmpty ? "empty-clear-ok" : "abXcd"
        #expect(session.snapshot().logicalLines().contains { $0.text == output },
            "\(shell): editor lost its buffer/cursor after Clear Screen\n\(session.snapshot().dump())")
    }
}
