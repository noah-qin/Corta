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
    @Test func appliedTemplateRestoresTheSplitTreeAndLeavesAgentCommandsUnsubmitted() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, host) = try makeWindow(limit: 6)
        defer { close(window, host) }
        host.space.setActive(true)
        host.space.openProject(root)
        let project = try #require(host.space.selectedProject)
        let oldSession = try #require(project.sessions.first)
        try "PROMPT='template> '; RPROMPT=''; HISTFILE=/dev/null\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var preset = Preset(name: "template-flow")
        preset.shell = "/bin/zsh"
        preset.environment = ["ZDOTDIR": root.path, "HOME": root.path]
        let oldPresets = ConfigurationStore.shared.configuration.presets
        _ = ConfigurationStore.shared.update { $0.presets.append(preset) }
        defer { _ = ConfigurationStore.shared.update { $0.presets = oldPresets } }
        let first = SpaceSessionRecord(number: 1, directory: root.path, presetName: preset.name)
        var second = SpaceSessionRecord(number: 2, directory: root.path, presetName: preset.name)
        second.conversation = LocalConversation(kind: .claude)
        let original = [first, second]
        let template = SpaceTemplate.capture(name: "flow", projectPath: root.path, sessions: original,
            members: [AgentMemberRecord(role: "review", sessionID: second.id, nudgeEnabled: false)],
            layout: .split(vertical: true, fraction: 0.4, first: .panel(0), second: .panel(1)))
        host.space.apply(template, to: project)
        #expect(project.sessions.count == 3)
        #expect(project.shown.map(\.id) == project.sessions.dropFirst().map(\.id))
        #expect(project.layout?.panels == [1, 2])
        #expect(oldSession.pane?.session?.pty.exitStatus == nil)
        let added = try #require(project.sessions.last)
        #expect(!original.map(\.id).contains(added.id))
        #expect(added.record.conversation == nil)
        #expect(project.members.last?.role == "review")
        #expect(project.members.last?.nudgeEnabled == false)
        try await waitForIssueFlow { visibleText(added).contains("claude") }
        #expect(added.pane?.session?.isCommandRunning == false)
        #expect(project.layout?.panels == [1, 2])
        let count = project.sessions.count
        var outside = template
        outside.sessions[0].directory = "/outside-corta-template"
        outside.sessions[0].outsideProject = true
        var warned = false
        host.space.presentAlert = { _, _, done in warned = true; done(.alertFirstButtonReturn) }
        host.space.apply(outside, to: project)
        #expect(warned)
        #expect(project.sessions.count == count)
    }

    @Test func templateSSHConfirmationIsSequentialAndCancelSkipsOnlyThatEntry() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, host) = try makeWindow()
        defer { RemoteConnectController.shared.close(); close(window, host) }
        host.space.setActive(true)
        host.space.openProject(root)
        let project = try #require(host.space.selectedProject)
        var first = SpaceSessionRecord(number: 1, ssh: SSHTarget(host: "first-fixture.invalid"))
        var second = SpaceSessionRecord(number: 2, ssh: SSHTarget(host: "second-fixture.invalid"))
        first.retainSSH = true
        second.retainSSH = false
        let local = SpaceSessionRecord(number: 3, directory: root.path)
        let template = SpaceTemplate.capture(name: "SSH confirmation", projectPath: root.path,
            sessions: [first, second, local], members: [], layout: .arranged([0, 1, 2], inColumns: true))
        var attempts = 0
        host.space.makeSSHPreset = { target, tmux in
            attempts += 1
            return SSHDestination.preset(for: target, retaining: tmux)
        }
        host.space.apply(template, to: project)
        try await waitForIssueFlow { RemoteConnectController.shared.window?.isVisible == true }
        #expect(project.sessions.count == 4)
        RemoteConnectController.shared.close()
        try await waitForIssueFlow {
            project.sessions.count == 3 && RemoteConnectController.shared.window?.isVisible == true
        }
        RemoteConnectController.shared.close()
        try await waitForIssueFlow {
            project.sessions.count == 2 && project.shown.count == 1 && project.layout?.panels == [1]
        }
        #expect(project.sessions.allSatisfy { $0.record.ssh == nil })
        #expect(attempts == 0)
        #expect(project.layout?.panels == [1])
    }

    @Test func sixPanelsMeetTheCellMinimumOnTheCurrentDisplay() async throws {
        let oldFont = ConfigurationStore.shared.configuration.fontSize
        _ = ConfigurationStore.shared.update { $0.fontSize = 10 }
        defer { _ = ConfigurationStore.shared.update { $0.fontSize = oldFont } }
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, host) = try makeWindow(limit: 6)
        defer { close(window, host) }
        host.space.setActive(true)
        host.space.openProject(root)
        for _ in 0..<5 { host.space.newSession() }
        let project = try #require(host.space.selectedProject)
        try #require(project.shown.count == 6)
        for session in project.shown {
            let grid = try #require(session.pane?.session?.snapshot())
            #expect(grid.columns >= 64)
            #expect(grid.rows >= 18)
            print("Space six-panel cells: \(grid.columns) × \(grid.rows)")
        }
        let focused = try #require(host.space.focusedSession)
        host.space.newSession()
        #expect(project.sessions.count == 7)
        #expect(project.shown.count == 6)
        #expect(project.shown.contains(focused))
    }

    @Test func waitingQueuePrioritizesAcrossHiddenPanelsAndAdvancesAfterHandling() async throws {
        let original = ConfigurationStore.shared.configuration
        _ = ConfigurationStore.shared.update { $0.agentStatus = true; $0.waitingQueueAutoAdvance = false }
        defer { _ = ConfigurationStore.shared.update { $0 = original } }
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        var preset = Preset(name: "waiting-flow")
        preset.shell = "/bin/cat"
        _ = ConfigurationStore.shared.update { $0.presets.append(preset) }
        let (window, host) = try makeWindow(limit: 2)
        defer { close(window, host) }
        let records = (1...3).map { SpaceSessionRecord(number: $0, directory: root.path, presetName: preset.name) }
        SpaceStore.standard.save(SpaceState(projects: [SpaceProjectRecord(path: root.path, sessions: records,
            layout: .split(vertical: true, fraction: 0.5, first: .panel(0), second: .panel(1)), nextNumber: 4)]))
        host.space.setActive(true)
        let project = try #require(host.space.selectedProject)
        for (index, kind) in ["question", "permission", "auth"].enumerated() {
            let session = project.sessions[index]
            session.pane?.session?.write(Array(("\u{1B}]7501;state=blocked:kind=" + kind + "\u{7}\n").utf8))
            try await waitForIssueFlow { session.pane?.agents.status?.state == .blocked }
        }
        #expect(host.space.waitingSessionIDs() == [records[2].id, records[1].id, records[0].id])
        host.space.jumpToNextWaiting()
        #expect(host.space.focusedSession?.id == records[2].id)
        #expect(project.shown.contains { $0.id == records[2].id })
        project.sessions[2].pane?.session?.write(Array("\u{1B}]7501;state=working\u{7}\n".utf8))
        try await waitForIssueFlow { project.sessions[2].pane?.agents.status?.state == .working }
        _ = ConfigurationStore.shared.update { $0.waitingQueueAutoAdvance = true }
        host.space.show(project.sessions[1])
        host.space.refreshNow()
        project.sessions[1].pane?.session?.write(Array("\u{1B}]7501;state=working\u{7}\n".utf8))
        try await waitForIssueFlow { host.space.focusedSession?.id == records[0].id }
        #expect(host.space.waitingSessionIDs() == [records[0].id])
        host.space.setActive(false)
        #expect(!host.space.isActive)
    }

    @Test func selectionMenuIsDisabledWithoutAPeerAndPausedDeliveryExplainsRefusal() async throws {
        let original = ConfigurationStore.shared.configuration.agentMessages
        _ = ConfigurationStore.shared.update { $0.agentMessages = true }
        defer { _ = ConfigurationStore.shared.update { $0.agentMessages = original } }
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, host) = try makeWindow()
        defer { close(window, host) }
        host.space.setActive(true)
        host.space.openProject(root)
        let source = try #require(host.space.focusedSession)
        let pane = try #require(source.pane)
        try await waitForIssueFlow { !visibleText(source).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        pane.selection = TerminalSelection(start: GridPosition(row: 0, column: 0),
                                           end: GridPosition(row: 0, column: 3))
        let project = try #require(host.space.selectedProject)
        let title = L10n.text("space.member.send")
        #expect(pane.commands.contextMenu().items.first { $0.title == title }?.isEnabled == false)
        project.members = [AgentMemberRecord(role: "self", sessionID: source.id)]
        #expect(pane.commands.contextMenu().items.first { $0.title == title }?.isEnabled == false)
        host.space.newSession()
        let peer = try #require(host.space.focusedSession)
        let paused = AgentMemberRecord(role: "paused", sessionID: peer.id, paused: true)
        project.members.append(paused)
        // Adding the peer resizes the source grid and correctly clears its old selection.
        pane.selection = TerminalSelection(start: GridPosition(row: 0, column: 0),
                                           end: GridPosition(row: 0, column: 3))
        #expect(pane.commands.contextMenu().items.first { $0.title == title }?.isEnabled == true)
        #expect(host.space.sendUserText("selected", to: paused, from: source) == .refused("paused"))
        #expect(AgentHub.shared.bus.peek(member: paused.id).isEmpty)
    }

    func visibleText(_ session: SpaceSession) -> String {
        guard let grid = session.pane?.session?.snapshot() else { return "" }
        return Selection.text(of: SelectionRange(anchor: SelectionPoint(row: 0, column: 0),
            head: SelectionPoint(row: grid.rows - 1, column: grid.columns - 1)), in: grid)
    }

    private func waitForIssueFlow(_ predicate: () -> Bool) async throws {
        let deadline = SuspendingClock.now.advanced(by: .seconds(10))
        while !predicate(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(predicate())
    }
}
