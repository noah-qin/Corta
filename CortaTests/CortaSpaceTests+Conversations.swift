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

extension CortaSpaceTests {
    private func withConversationFixture(
        skipping: Set<Int> = [], rightPrompt: String = "", picker: Bool = false, typedInput: Bool = false,
        _ body: (CortaSpaceController, SpaceProject) async throws -> Void
    ) async throws {
        let (controller, host) = try makeWindow(limit: 2)
        defer { close(controller, host) }
        let folder = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "PROMPT='demo> '\nRPROMPT='\(rightPrompt)'\nHISTFILE=/dev/null\n".write(
            to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        if typedInput {
            let shellRC = folder.appendingPathComponent(".zshrc")
            let script = try String(contentsOf: shellRC, encoding: .utf8)
                + "zle-line-init() { BUFFER='user input'; CURSOR=0; }; zle -N zle-line-init\n"
            try script.write(to: shellRC, atomically: true, encoding: .utf8)
        }
        var preset = Preset(name: "conversation-fixture")
        preset.shell = "/bin/zsh"
        preset.environment = ["ZDOTDIR": folder.path, "HOME": folder.path]
        let oldPresets = ConfigurationStore.shared.configuration.presets
        _ = ConfigurationStore.shared.update { $0.presets.append(preset) }
        defer { _ = ConfigurationStore.shared.update { $0.presets = oldPresets } }
        let ids = ["3f2a9c1e-7b14-4d2e-9a6f-1c8e0b44d912", "019eee77-052d-7530-af09-17a140e08123",
                   "2b20121e-9a9b-43cb-b12e-fde980cb41e0"]
        let records = ids.enumerated().map { index, raw in
            var record = SpaceSessionRecord(number: index + 1, directory: folder.path, presetName: preset.name)
            if !skipping.contains(index) {
                record.conversation = LocalConversation(kind: index == 2 ? .codex : .claude,
                                                        id: picker ? nil : UUID(uuidString: raw))
            }
            return record
        }
        SpaceStore.standard.save(SpaceState(projects: [SpaceProjectRecord(
            path: folder.path, sessions: records,
            layout: .split(vertical: true, fraction: 0.5, first: .panel(0), second: .panel(1)), nextNumber: 4)]))
        host.space.setActive(true)
        try await body(host.space, try #require(host.space.selectedProject))
    }

    private func waitForConversation(
        _ message: String = "", diagnostic: () -> String = { "" }, predicate: () -> Bool
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(10 * Double(testTimeoutScale))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), Comment(rawValue: message + diagnostic()))
    }

    /// Compare logical terminal text: other appearance suites may resize a
    /// live pane while this test yields, wrapping a command across grid rows.
    private func conversationText(_ terminal: TerminalSession?) -> String {
        guard let grid = terminal?.snapshot() else { return "" }
        return Selection.text(of: SelectionRange(
            anchor: SelectionPoint(row: 0, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1)), in: grid)
    }

    private func conversationNoteText(in space: CortaSpaceController) -> String? {
        let glass = space.content.view.subviews.compactMap { $0 as? NSGlassEffectView }.last
        let row = glass?.contentView as? NSStackView
        #expect(row?.arrangedSubviews.contains { $0 is NSButton } != true, "no Undo for a conversation fill")
        return (row?.arrangedSubviews.first as? NSTextField)?.stringValue
    }

    @Test func localConversationsFillTheirOwnPromptsWithoutExecutingAndHiddenOnesExplainLater() async throws {
        try await withConversationFixture { space, project in
            try await waitForConversation { project.sessions.allSatisfy { item in
                guard let command = item.record.conversation?.command else { return false }
                return conversationText(item.pane?.session).contains(command)
            } }
            try await waitForConversation {
                conversationNoteText(in: space) == L10n.text("space.conversation.filledMany")
            }
            for item in project.sessions {
                let terminal = try #require(item.pane?.session)
                #expect(!terminal.isCommandRunning)
                #expect(terminal.commandRecords.records.allSatisfy { $0.exitStatus == nil }, "no Return was sent")
                #expect(!space.canFillConversation(item), "filled prompts are no longer empty")
            }
            let hidden = project.sessions[2]
            let command = try #require(hidden.record.conversation).command
            #expect(!project.shown.contains(hidden))
            #expect(hidden.conversationNeedsNotice)
            space.show(hidden)
            space.refreshNow()
            #expect(conversationNoteText(in: space) == L10n.text("space.conversation.continue"))
            let terminal = try #require(hidden.pane?.session)
            terminal.write([0x15]) // The user discards the unsubmitted line.
            try await waitForConversation { space.canFillConversation(hidden) }
            space.setActive(false)
            space.setActive(true)
            #expect(!conversationText(terminal).contains(command))
            #expect(space.fillConversation(hidden), "explicit refill is still a fill, never a run")
            try await waitForConversation { conversationText(terminal).contains(command) }
            #expect(!terminal.isCommandRunning)
        }
    }

    @Test func missingRecordFillsPickersAndUsesTheSinglePickerNotice() async throws {
        try await withConversationFixture(skipping: [1, 2], picker: true) { space, project in
            let item = project.sessions[0]
            try await waitForConversation {
                conversationNoteText(in: space) == L10n.text("space.conversation.pickerFilled")
            }
            let text = conversationText(item.pane?.session)
            #expect(text.contains("claude --resume"))
            #expect(!text.contains("--continue"))
            #expect(!text.contains("--last"))
            #expect(item.pane?.session?.isCommandRunning == false)
        }
        try await withConversationFixture(picker: true) { space, project in
            try await waitForConversation {
                conversationNoteText(in: space) == L10n.text("space.conversation.filledMany")
            }
            for item in project.sessions {
                #expect(conversationText(item.pane?.session).contains(try #require(item.record.conversation).command))
                #expect(item.pane?.session?.isCommandRunning == false)
            }
        }
    }

    @Test func typedPromptsAreFailedFillsAndNeverCountAsFilled() async throws {
        try await withConversationFixture(typedInput: true) { space, project in
            try await waitForConversation { project.sessions.allSatisfy {
                conversationText($0.pane?.session).contains("user input")
            } }
            try await Task.sleep(for: .seconds(1))
            for item in project.sessions {
                #expect(!space.canFillConversation(item))
                #expect(!space.fillConversation(item))
                let text = conversationText(item.pane?.session)
                #expect(!text.contains("--resume"))
                #expect(!item.conversationNeedsNotice)
            }
            #expect(conversationNoteText(in: space) == nil)
        }
    }

    @Test func aRightPromptStillReceivesTheResumeCommand() async throws {
        try await withConversationFixture(rightPrompt: "RIGHT") { _, project in
            let item = project.sessions[0]
            let command = try #require(item.record.conversation).command
            try await waitForConversation("RPROMPT must not look like typed text") {
                conversationText(item.pane?.session).contains(command)
                    && conversationText(item.pane?.session).contains("RIGHT")
            }
            #expect(item.pane?.session?.isCommandRunning == false)
        }
    }

    @Test func onlySuccessfulFillsCountAndTheNoteDisappearsWithoutDeletingTheCommand() async throws {
        try await withConversationFixture(skipping: [1, 2]) { space, project in
            let first = project.sessions[0]
            let command = try #require(first.record.conversation).command
            try await waitForConversation { conversationNoteText(in: space) == L10n.text("space.conversation.filled") }
            for item in project.sessions.dropFirst() {
                let text = conversationText(item.pane?.session)
                #expect(!text.contains("resume"))
                #expect(!item.conversationNeedsNotice)
            }
            try await waitForConversation { conversationNoteText(in: space) == nil }
            let text = conversationText(first.pane?.session)
            #expect(text.contains(command))
            #expect(first.pane?.session?.isCommandRunning == false)
        }
    }

    @Test func processSamplingReplacesTheConversationAndKeepsItAfterTheProcessExits() async throws {
        try await withConversationFixture { space, project in
            let item = project.sessions[0]
            let terminal = try #require(item.pane?.session)
            let oldCommand = try #require(item.record.conversation).command
            try await waitForConversation("initial command") { conversationText(terminal).contains(oldCommand) }
            let executable = project.url.appendingPathComponent("codex")
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
            // A copied Apple platform binary may be killed at exec. Sign only
            // this disposable copy so the fixture has an ordinary local identity.
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = ["--force", "--sign", "-", executable.path]
            try signer.run()
            signer.waitUntilExit()
            try #require(signer.terminationStatus == 0)
            let ids = [UUID(), UUID()]
            for uuid in ids {
                terminal.write([0x15])
                try await waitForConversation("empty prompt before launching fixture") {
                    space.canFillConversation(item)
                }
                let name = "rollout-2026-10-29T09-00-00-" + uuid.uuidString + ".jsonl"
                let file = project.url.appendingPathComponent(name)
                let command = PaneCommands.shellQuoted(executable.path) + " 30 3>" + PaneCommands.shellQuoted(file.path)
                terminal.write(Array((command + "\r").utf8)) // Explicit fixture Return, not a restoration action.
                try await waitForConversation("foreground codex", diagnostic: {
                    "\nprocess: " + (terminal.foregroundProcessName ?? "nil") + "\n" + terminal.snapshot().dump()
                }, predicate: { terminal.foregroundProcessName == "codex" })
                await space.sampleConversations()
                let expected = LocalConversation(kind: .codex, id: uuid)
                #expect(item.record.conversation == expected)
                terminal.write([0x03]) // Interrupt only this fixture child.
                try await waitForConversation("returned shell") {
                    terminal.foregroundProcessName == nil && !terminal.isCommandRunning
                }
                await space.sampleConversations()
                #expect(item.record.conversation == expected, "the last observed conversation survives exit")
                space.saveNow()
                #expect(SpaceStore.standard.load().projects[0].sessions[0].conversation == expected)
            }
        }
    }

    @Test func confirmedMixedGroupClearsThePersistedIdentity() async throws {
        try await withConversationFixture { space, project in
            let item = project.sessions[0]
            try await waitForConversation { !space.canFillConversation(item) }
            #expect(item.record.conversation != nil)
            space.applyConversationSample(.mixedProcesses, to: item)
            #expect(item.record.conversation == nil)
            #expect(item.conversationObservation == nil)
            #expect(!space.canFillConversation(item))
            space.saveNow()
            #expect(SpaceStore.standard.load().projects[0].sessions[0].conversation == nil)
        }
    }

}
