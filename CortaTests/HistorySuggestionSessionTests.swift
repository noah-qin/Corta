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
import CortaTerminal
@testable import Corta

@MainActor struct HistorySuggestionSessionTests {
    private func withSession(
        startup: String = "", directory: Bool = true, history: Bool = true,
        _ body: (TerminalSession) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("corta-history-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try fileManager.createDirectory(at: home.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        let zshrcScript = "PS1='READY> '\nHISTFILE=/dev/null\n" + startup + "\n"
        try zshrcScript.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let prepared = ZshBootstrap.prepare([
            "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/bin:/usr/bin", "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8", "TERM_PROGRAM": "Corta",
        ], executable: "/bin/zsh", arguments: ["-l"], directoryCompletion: directory, historySuggestions: history)
        let env = prepared.environment, made = prepared.folder, token = prepared.token
        let folder = try #require(made)
        defer { ZshBootstrap.remove(folder) }
        let session = try TerminalSession(executable: "/bin/zsh", arguments: ["-l"], environment: env,
            size: TerminalSize(rows: 40, columns: 160), workingDirectory: home.path,
            directoryCompletionToken: token)
        defer { session.stop() }
        session.start()
        try wait(session) { session.promptEndPosition != nil }
        try body(session)
        #expect(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8) == zshrcScript)
    }

    private func wait(_ session: TerminalSession, _ predicate: () -> Bool) throws {
        let end = SuspendingClock.now + .seconds(5 * Double(testTimeoutScale))
        while SuspendingClock.now < end {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(Bool(false), "\(session.snapshot().dump())")
    }
    private func write(_ session: TerminalSession, _ text: String) { session.write(Array(text.utf8)) }

    @Test func newestLiteralPrefixWinsAndShellAcceptsWithoutExecuting() throws {
        try withSession(startup: "print -s -- 'echo older'\nprint -s -- 'echo newest'") { session in
            write(session, "echo ")
            try wait(session) { session.historySuggestion?.suffix == "newest" }
            write(session, "\u{1b}[95~")
            try wait(session) {
                session.historySuggestion == nil && session.snapshot().dump().contains("READY> echo newest")
            }
            #expect(!session.isCommandRunning)
            #expect(
                session.commandRecords.records.compactMap(\.exitStatus).isEmpty, "acceptance never executes the command"
            )
            write(session, "\u{15}print -s -- 'echo [literal]* 中文'\r")
            try wait(session) { session.commandRecords.records.contains { $0.exitStatus == 0 } }
            write(session, "echo [")
            try wait(session) { session.historySuggestion?.suffix == "literal]* 中文" }
            write(session, "\u{1b}[94~")
            try wait(session) { session.historySuggestion == nil }
            write(session, "l")
            try wait(session) { session.historySuggestion?.suffix == "iteral]* 中文" }
        }
    }

    @Test func shorteningPrefixSearchesAgainForTheNewestMatch() throws {
        try withSession(startup: "print -s -- 'echo abc'\nprint -s -- 'echo abd'") { session in
            write(session, "echo ab")
            try wait(session) { session.historySuggestion?.suffix == "d" }
            write(session, "c")
            try wait(session) { session.historySuggestion == nil }
            write(session, "\u{7f}")
            try wait(session) { session.historySuggestion?.suffix == "d" }
        }
    }

    @Test func escapeInViInsertModeAlsoEntersCommandMode() throws {
        try withSession(startup: "bindkey -v\nprint -s -- 'echo vi-mode'") { session in
            write(session, "echo ")
            try wait(session) { session.historySuggestion?.suffix == "vi-mode" }
            write(session, "\u{1b}[94~")
            try wait(session) { session.historySuggestion == nil }
            // `0iX` is a motion and an insert in command mode, text in insert mode.
            write(session, "0iX")
            try wait(session) { session.snapshot().dump().contains("READY> Xecho") }
        }
    }

    @Test func aMissStaysAMissAndNewHistoryIsFound() throws {
        try withSession(startup: "print -s -- 'echo known'") { session in
            write(session, "echo z")
            try wait(session) { session.snapshot().dump().contains("READY> echo z") }
            write(session, "zz")
            try wait(session) { session.snapshot().dump().contains("READY> echo zzz") }
            #expect(session.historySuggestion == nil)
            write(session, "\u{15}print -s -- 'echo zzz-new'\r")
            try wait(session) { session.commandRecords.records.contains { $0.exitStatus == 0 } }
            write(session, "echo zzz")
            try wait(session) { session.historySuggestion?.suffix == "-new" }
        }
    }

    @Test func emptyMidlineMultilineAndCdDoNotSuggestHistory() throws {
        try withSession(
            startup: "print -s -- 'echo single'\nprint -s -- $'echo multi\\nline'\nprint -s -- 'cd Alternative'"
        ) { session in
            #expect(session.historySuggestion == nil)
            write(session, "echo ")
            try wait(session) { session.historySuggestion?.suffix == "single" }
            write(session, "\u{2}") // move left
            try wait(session) { session.historySuggestion == nil }
            write(session, "\u{5}") // end of line
            try wait(session) { session.historySuggestion?.suffix == "single" }
            write(session, "\u{15}echo m")
            try wait(session) {
                session.historySuggestion == nil && session.snapshot().dump().contains("READY> echo m")
            }
            write(session, "\u{15}cd A")
            try wait(session) { session.directoryCompletion?.candidates == ["Alpha/"] }
            #expect(session.historySuggestion == nil)
        }
    }

    @Test(arguments: ["ZSH_AUTOSUGGEST_STRATEGY=history", "zle -N autosuggest-accept __corta_unused"])
    func existingAutosuggestionsWin(plugin: String) throws {
        try withSession(startup: "print -s -- 'echo original'\n" + plugin) { session in
            write(session, "echo o")
            try wait(session) { session.snapshot().dump().contains("READY> echo o") }
            #expect(session.historySuggestion == nil)
            write(session, "\u{15}cd A")
            try wait(session) { session.directoryCompletion?.candidates == ["Alpha/"] }
        }
    }

    @Test func settingsAreIndependent() throws {
        try withSession(startup: "print -s -- 'cd Alpha'\nprint -s -- 'echo enabled'", directory: false) { session in
            write(session, "echo ")
            try wait(session) { session.historySuggestion?.suffix == "enabled" }
            // With directory suggestions off, `cd ` input gets history ones.
            write(session, "\u{15}cd A")
            try wait(session) { session.historySuggestion?.suffix == "lpha" }
            #expect(session.directoryCompletion?.candidates.isEmpty != false)
        }
        try withSession(startup: "print -s -- 'echo disabled'", history: false) { session in
            write(session, "echo d")
            try wait(session) { session.snapshot().dump().contains("READY> echo d") }
            #expect(session.historySuggestion == nil)
            write(session, "\u{15}cd A")
            try wait(session) { session.directoryCompletion?.candidates == ["Alpha/"] }
        }
    }
}
