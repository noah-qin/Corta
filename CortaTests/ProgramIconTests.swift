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

import AppKit
import CortaTerminal
import Testing

@testable import Corta

@MainActor
struct ProgramIconTests {
    @Test func recognisesVersionedProcessesAndFallsBackForUnknownPrograms() {
        for name in ["python", "python3", "Python3.13", "/usr/bin/python3.9"] {
            #expect(ProgramIcon.identify(name) == .python)
        }
        #expect(ProgramIcon.identify("claude-code") == .claude)
        #expect(ProgramIcon.identify("codex-aarch64-apple-darwin") == .codex)
        #expect(ProgramIcon.identify("kimi") == .kimi)
        for name in [nil, "zsh", "python-not-a-version", "my-claude-notes"] {
            #expect(ProgramIcon.identify(name) == .terminal)
        }
    }

    @Test func commonCLIsAndInterpreterEntrypointsHaveDistinctIcons() {
        let commands: [(String, ProgramIcon)] = [
            ("grok", .grok), ("gemini", .gemini), ("qwen", .qwen), ("aider", .aider),
            ("opencode", .opencode), ("ollama", .ollama), ("copilot", .copilot), ("goose", .goose),
            ("node", .node), ("bun", .bun), ("deno", .deno), ("irb", .ruby), ("go", .go),
            ("cargo", .rust), ("jshell", .java), ("php8.3", .php), ("lua5.4", .lua),
            ("swift", .swift), ("julia", .julia), ("R", .r), ("ssh", .ssh), ("sftp", .sftp),
            ("mosh-client", .mosh), ("lazygit", .git), ("docker", .docker), ("k9s", .kubernetes),
            ("vim", .vim), ("nvim", .neovim), ("emacs", .emacs), ("tmux", .tmux),
            ("screen", .screen), ("npm", .npm), ("pnpm", .pnpm), ("yarn", .yarn),
            ("psql", .postgres), ("mysql", .mysql), ("redis-cli", .redis), ("sqlite3", .sqlite),
            ("htop", .top),
        ]
        for (command, icon) in commands { #expect(ProgramIcon.identify(command) == icon) }
        let claudeCode = "/opt/node_modules/@anthropic-ai/claude-code/cli.js"
        #expect(ProgramIcon.identify("node", entryPoint: claudeCode) == .claude)
        #expect(ProgramIcon.identify("node", entryPoint: "/opt/node_modules/@google/gemini-cli/index.js") == .gemini)
        #expect(ProgramIcon.identify("Python", entryPoint: "/venv/bin/kimi") == .kimi)
        #expect(ProgramIcon.identify("python3", entryPoint: "kimi_cli") == .kimi)
        #expect(ProgramIcon.identify("node", entryPoint: "/projects/claude-code/main.js") == .node)
        #expect(ProgramIcon.identify("ssh", entryPoint: "claude") == .ssh)
    }

    @Test func everyProgramHasBundledArtworkAndReadableTabTiles() throws {
        for program in ProgramIcon.allCases {
            let mark = try #require(program.symbol)
            #expect(mark.isValid)
            let tile = try #require(program.tabImage)
            #expect(tile.tiffRepresentation != nil)
            #expect(!tile.isTemplate)
        }
        #expect(AcknowledgementsView.programIconLicenses.contains("Copyright (c) 2023 LobeHub"))
        #expect(AcknowledgementsView.programIconLicenses.contains("CC0 1.0 Universal"))
    }

    @Test func brandDoesNotComeFromAProgramSuppliedWindowTitle() async throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/usr")
        defer { session.stop() }
        let title = PaneWindowTitle()
        title.reset(session: session)
        defer { title.stop() }
        session.start()
        session.write(Array("\u{1B}]2;Claude\u{07}\n".utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while session.windowTitle == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.windowTitle == "Claude")
        #expect(title.tabLabel.icon == .terminal)
        #expect(title.tabLabel.name == "cat")
        #expect(title.tabLabel.context == "usr")
    }
}
