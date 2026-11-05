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

/// The Agents list's order and the jump, on real panes across tabs and windows,
/// their state set by the same OSC 7501 bytes a program sends.
@MainActor
@Suite(.serialized)
struct AgentJumpTests {
    private func makeWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        controller.selectedTab?.split.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func close(_ controllers: TerminalWindowController...) {
        for controller in controllers {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
    }

    /// The shell prints it, so it travels the PTY → parser path.
    private func report(_ state: String, in pane: ViewController) async throws {
        let marker = UUID().uuidString
        let command = "printf '\\033]7501;\(state)\\033\\\\\\033]2;\(marker)\\033\\\\'\n"
        pane.session.write(Array(command.utf8))
        let deadline = SuspendingClock.now + .seconds(15 * testTimeoutScale)
        while pane.session.windowTitle != marker, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pane.session.windowTitle == marker)
        pane.agents.readOutput()
    }

    private func id(_ pane: ViewController) -> UUID { pane.taskNotifier.paneID }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func waitingPanesLeadTheListThenTheRestByUrgency() async throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let working = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        let question = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .rows)
        split.splitTransition.finish()
        let auth = try #require(split.focusedPane)

        try await report("state=working", in: working)
        try await report("state=blocked:kind=question", in: question)
        try await report("state=blocked:kind=auth", in: auth)

        let order = AgentDirectory.entries.map(\.id).filter { [id(working), id(question), id(auth)].contains($0) }
        #expect(order == [id(auth), id(question), id(working)])
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theJumpReachesAHiddenTabAndAnotherWindowWithTheKeyboard() async throws {
        let first = makeWindow(), second = makeWindow()
        defer { close(first, second) }
        let hiddenTab = first.addTab(select: false)
        let hidden = try #require(hiddenTab.split.focusedPane)
        let other = try #require(second.selectedTab?.split.focusedPane)
        try await report("state=blocked:kind=auth", in: hidden)
        try await report("state=blocked:kind=permission", in: other)

        AgentDirectory.jumpToNextWaiting()
        #expect(first.selectedTab === hiddenTab)
        #expect(hiddenTab.split.focusedPane === hidden)
        #expect(first.window?.firstResponder === hidden.terminalView)

        AgentDirectory.jumpToNextWaiting()
        #expect(second.selectedTab?.split.focusedPane === other)
        #expect(second.window?.firstResponder === other.terminalView)
    }

    /// A sibling zoomed over the target detaches it, so it has no window of its
    /// own to come forward in.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theJumpUnzoomsASiblingCoveringTheTarget() async throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let target = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        try await report("state=blocked:kind=question", in: target)
        split.toggleZoomPane(nil)
        #expect(split.isPaneZoomed)
        #expect(target.view.window == nil)

        AgentDirectory.jumpToNextWaiting()

        #expect(!split.isPaneZoomed)
        #expect(split.focusedPane === target)
        #expect(controller.window?.firstResponder === target.terminalView)
    }

    /// Only the user's command moves focus: a report alone leaves it, and nothing
    /// waiting leaves the jump with nothing to do.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aReportMovesNothingAndAnEmptyQueueChangesNothing() async throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let target = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        let focused = try #require(split.focusedPane)

        AgentDirectory.jumpToNextWaiting()
        #expect(split.focusedPane === focused)

        try await report("state=blocked:kind=auth", in: target)
        #expect(split.focusedPane === focused, "the report alone moved focus")
        try await report("state=done", in: target)
        AgentDirectory.jumpToNextWaiting()
        #expect(split.focusedPane === focused, "done is not waiting")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func agentStatusOffDisablesTheCommandAndEmptiesTheList() async throws {
        let store = ConfigurationStore.shared
        let controller = makeWindow()
        defer {
            _ = store.update { $0.agentStatus = true }
            close(controller)
        }
        let split = try #require(controller.selectedTab?.split)
        let target = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        let focused = try #require(split.focusedPane)
        try await report("state=blocked:kind=auth", in: target)
        #expect(AgentDirectory.hasWaitingPane)

        _ = store.update { $0.agentStatus = false }
        for pane in split.panes { pane.agents.readOutput() }

        #expect(!AgentDirectory.hasWaitingPane)
        #expect(AgentDirectory.entries.isEmpty)
        #expect(!TerminalCommand.nextWaitingPane.isOfferedInPalette)
        AgentDirectory.jumpToNextWaiting()
        #expect(split.focusedPane === focused)
    }
}
