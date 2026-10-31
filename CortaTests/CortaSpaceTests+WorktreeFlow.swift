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
import Foundation
import Testing
@testable import Corta

extension CortaSpaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_WORKTREE_TEST_ROOT"] != nil))
    func worktreeFormFillsWithoutRunningAndUserReturnUpdatesItsGitRow() async throws {
        try #require(ProcessInfo.processInfo.environment["SHELL"] == "/bin/zsh",
                     "Use a temporary XCTest environment overlay; the normal Unit plan deliberately uses sh")
        let path = try #require(ProcessInfo.processInfo.environment["CORTA_WORKTREE_TEST_ROOT"])
        let root = URL(fileURLWithPath: path).appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = try #require(WorktreeCommand.location(projectPath: root.path, name: "topic"))
        defer {
            try? FileManager.default.removeItem(atPath: destination)
            try? FileManager.default.removeItem(at: root)
        }
        try fixtureGit(["init", "-b", "main", root.path])
        try fixtureGit(["-C", root.path, "-c", "user.name=Acceptance", "-c", "user.email=test@example.invalid",
                        "commit", "--allow-empty", "-m", "fixture"])
        let (window, host) = try makeWindow()
        defer { close(window, host) }
        host.space.setActive(true)
        host.space.openProject(root)
        let source = try #require(host.space.focusedSession)
        host.space.presentAlert = { alert, _, done in
            let fields = alert.accessoryView?.subviews.compactMap { $0 as? NSTextField } ?? []
            guard fields.count == 3 else { Issue.record("worktree form fields missing"); return }
            fields[1].stringValue = "topic"
            fields[2].stringValue = "corta-topic"
            done(.alertFirstButtonReturn)
        }
        host.space.promptWorktree(from: source)
        let first = try #require(host.space.focusedSession)
        try await waitForWorktreeFlow { visibleText(first).contains("git worktree add") }
        #expect(!FileManager.default.fileExists(atPath: destination))
        let clear = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{15}", charactersIgnoringModifiers: "u",
            isARepeat: false, keyCode: 32))
        first.pane?.terminalView.keyDown(with: clear)
        try await waitForWorktreeFlow { !visibleText(first).contains("git worktree add") }
        #expect(!FileManager.default.fileExists(atPath: destination))
        host.space.promptWorktree(from: source)
        let second = try #require(host.space.focusedSession)
        try await waitForWorktreeFlow { visibleText(second).contains("git worktree add") }
        #expect(!FileManager.default.fileExists(atPath: destination))
        try await submitNativeAgentPrompt("", in: second)
        try await waitForWorktreeFlow { second.pane?.session?.currentDirectory == destination }
        host.space.noteGitDirectories()
        try await waitForWorktreeFlow { host.space.gitFacts[second.id]?.worktree == true }
        #expect(host.space.gitFacts[second.id]?.name == "corta-topic")
        print("REAL worktree fill, delete, explicit Return, OSC 7 and Git mark")
    }

    private func fixtureGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func waitForWorktreeFlow(_ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now.advanced(by: .seconds(10))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(predicate())
    }
}
