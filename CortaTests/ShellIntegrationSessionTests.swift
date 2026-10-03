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

    private func exercise(shell: String, fishFallback: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-shell-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "CORTA-READY> "
        var environment = [
            "HOME": directory.path, "ZDOTDIR": directory.path,
            "XDG_CONFIG_HOME": directory.path, "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LC_ALL": "C",
        ]
        let script: String
        let arguments: [String]
        if shell.hasSuffix("zsh") {
            script = "PS1='\(prompt)'\n" + ShellIntegrationScript.zsh
            let rc = directory.appendingPathComponent(".zshrc")
            try script.write(to: rc, atomically: true, encoding: .utf8)
            arguments = ["-d", "-i"]
        } else if shell.hasSuffix("bash") {
            script = "PS1='\(prompt)'\n" + ShellIntegrationScript.bash
            let rc = directory.appendingPathComponent("bashrc")
            try script.write(to: rc, atomically: true, encoding: .utf8)
            arguments = ["--noprofile", "--rcfile", rc.path, "-i"]
        } else {
            if fishFallback { environment["fish_features"] = "no-mark-prompt" }
            script = "function fish_prompt; printf '\(prompt)'; end\n" + ShellIntegrationScript.fish
            let rc = directory.appendingPathComponent("init.fish")
            try script.write(to: rc, atomically: true, encoding: .utf8)
            arguments = ["--no-config", "-i", "-C", "source " + rc.path]
        }
        let session = try TerminalSession(
            executable: shell, arguments: arguments, environment: environment,
            size: TerminalSize(rows: 40, columns: 120), workingDirectory: directory.path)
        defer { session.stop() }
        session.start()

        func waitForPrompt(after row: Int) throws {
            let deadline = ContinuousClock.now + .seconds(10) * testTimeoutScale
            while ContinuousClock.now < deadline {
                if let record = session.commandRecords.last,
                   record.promptRow > row, record.promptEndColumn == prompt.count {
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(Bool(false), "\(shell), fallback=\(fishFallback): prompt timed out\n\(session.snapshot().dump())")
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
    }
}
