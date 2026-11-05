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

    /// Gemini's SVG once drew a dot: Xcode's reader stopped at run-together
    /// arc flags. Every mark must cover a real part of its tile.
    @Test(arguments: ProgramIcon.allCases)
    func everyMarkFillsItsTile(_ program: ProgramIcon) throws {
        let tile = try #require(program.tabImage)
        let side = 48
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side * 4 / 3, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        tile.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        let ground = try #require(rep.colorAt(x: 1, y: 1))
        var differing = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let distance = abs(color.redComponent - ground.redComponent)
                    + abs(color.greenComponent - ground.greenComponent)
                    + abs(color.blueComponent - ground.blueComponent)
                if distance > 0.3 { differing += 1 }
            }
        }
        // The 12 pt mark sits on a 24 × 18 tile: a fair mark covers well
        // over 4% of it; Gemini's dot covered under 1%.
        #expect(Double(differing) / Double(rep.pixelsWide * rep.pixelsHigh) > 0.04, "\(program)")
    }

    /// Java's tile read as Claude's: orange on orange at tab size.
    @Test func javaDoesNotWearClaudesColour() throws {
        let java = try #require(ProgramIcon.java.tabImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let claude = try #require(ProgramIcon.claude.tabImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let javaGround = try #require(NSBitmapImageRep(cgImage: java).colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        let claudeGround = try #require(NSBitmapImageRep(cgImage: claude).colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        #expect(abs(javaGround.hueComponent - claudeGround.hueComponent) > 0.25)
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
        let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        while session.windowTitle == nil, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.windowTitle == "Claude")
        #expect(title.tabLabel.icon == .terminal)
        #expect(title.tabLabel.name == "cat")
        #expect(title.tabLabel.context == "usr")
    }

    /// A program wears its icon once it takes the terminal, not while it
    /// runs and prints like `java -version`: that one flashed by and read as
    /// another program's.
    @Test func onlyAProgramThatTakesTheTerminalWearsItsIcon() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("repl.py")
        // Takes the terminal only when told to: a fixed pause lost the race
        // whenever Python took longer than it to start.
        try "import sys, time, tty\nsys.stdin.buffer.read(1)\ntty.setraw(0)\ntime.sleep(30)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let session = try TerminalSession(
            executable: "/usr/bin/python3", arguments: [script.path], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: folder.path)
        defer { session.stop() }
        let title = PaneWindowTitle()
        title.reset(session: session)
        defer { title.stop() }
        session.start()
        func label(until done: (ProgramTabLabel) -> Bool) async throws -> ProgramTabLabel {
            let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
            while true {
                title.invalidateProcessFacts()
                let label = title.tabLabel
                if done(label) || SuspendingClock.now >= deadline { return label }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let running = try await label { $0.name.lowercased().hasPrefix("python") }
        #expect(running.icon == .terminal, "still in canonical mode: no icon")
        _ = session.write(Array("\n".utf8))
        let interactive = try await label { $0.icon != .terminal }
        #expect(interactive.icon == .python)
    }
}
