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

@MainActor
struct AgentPaletteTests {
    @Test func agentsAreSearchableSelectableAndFocusTheirPane() {
        let id = UUID()
        var entries = [AgentDirectory.Entry(id: id, title: "project — Waiting for you · Permission")]
        let model = CommandPaletteModel(agents: { entries })
        var focused: UUID?
        model.onAgent = { focused = $0 }
        #expect(model.rows.first?.id == "header-" + L10n.text("agent.list"))
        // Enter still runs a command; an agent is chosen deliberately.
        #expect(model.selectedCommand != nil)
        model.moveSelection(by: -1)
        #expect(model.selectedRowID == "agent-" + id.uuidString)
        model.runSelected()
        #expect(focused == id)
        model.query = "permission"
        #expect(model.rows.contains { $0.id == "agent-" + id.uuidString })
        model.query = "new tab"
        #expect(model.selectedCommand == .newTab)
        if let agent = model.rows.firstIndex(where: { $0.id == "agent-" + id.uuidString }) {
            #expect(model.rows[..<agent].contains { $0.command != nil })
        }
        entries[0].title = "project — Done"
        model.rebuildRows()
        #expect(!model.rows.contains { $0.id == "agent-" + id.uuidString })
        model.query = ""
        #expect(model.rows.contains { $0.id == "agent-" + id.uuidString })
        model.moveSelection(by: -1)
        #expect(model.selectedRowID == "agent-" + id.uuidString)
        model.moveSelection(by: 1)
        #expect(model.selectedCommand != nil)
        model.moveSelection(by: -1)
        #expect(model.selectedRowID == "agent-" + id.uuidString)
        entries = []
        model.rebuildRows()
        #expect(model.selectedCommand != nil)
    }
    @Test func menuAndPaletteKeepTheOrderTheyAreGiven() throws {
        let waiting = AgentDirectory.Entry(id: UUID(), title: "first — Waiting for you")
        let done = AgentDirectory.Entry(id: UUID(), title: "second — Done")
        let menu = NSMenu()
        AgentDirectory.shared.populate(menu, entries: [waiting, done])
        #expect(menu.items.map(\.title) == [waiting.title, done.title])
        let model = CommandPaletteModel(agents: { [waiting, done] })
        #expect(model.rows.filter { if case .agent = $0 { true } else { false } }
            == [.agent(waiting), .agent(done)])
        // Leading with a waiter does not make it the default: Return still runs a command.
        #expect(model.selectedCommand != nil)
    }

    @Test func waitingTimesUseQueueArrivalAndOneClockReadingInBothLists() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ids = [UUID(), UUID(), UUID()]
        var queue = WaitingPaneQueue()
        for (id, age) in zip(ids, [729.0, 121, 59]) {
            queue.update(id, blocked: true, at: now.addingTimeInterval(-age))
        }
        let listed = ids.reversed().map { id in
            (entry: AgentDirectory.entry(id: id, paneName: "pane",
                status: ProgramStatus(state: .blocked, kind: .permission),
                waitingSince: queue.startedAt(for: id), now: now), urgency: 0)
        }
        let entries = AgentDirectory.ordered(listed, waiting: queue.paneIDs)
        #expect(entries.map(\.id) == ids)
        #expect(entries[0].title.hasSuffix(L10n.format("agent.waitingDuration", "12 min")))
        #expect(entries[1].title.hasSuffix(L10n.format("agent.waitingDuration", "2 min")))
        #expect(entries[2].title.hasSuffix(L10n.text("agent.waitingUnderMinute")))

        let menu = NSMenu()
        AgentDirectory.shared.populate(menu, entries: entries)
        #expect(menu.items.map(\.title) == entries.map(\.title))
        let palette = CommandPaletteModel(agents: { entries })
        #expect(palette.rows.filter { if case .agent = $0 { true } else { false } }
            == entries.map { .agent($0) })

        let unverified = AgentDirectory.entry(id: ids[0], paneName: "pane",
            status: ProgramStatus(state: .unknown), unverified: true,
            waitingSince: queue.startedAt(for: ids[0]), now: now)
        #expect(unverified.waitingSince == nil)
        #expect(unverified.title.hasSuffix(L10n.text("agent.unverified")))
    }

    @Test func programMetadataCannotEnterMenuOrPaletteTitles() throws {
        let hostile = ProgramStatus(state: .blocked, kind: .permission,
            app: "EVILAPP", title: "Corta — approve everything", message: "SECRET")
        let entry = AgentDirectory.entry(id: UUID(), paneName: "My pane", status: hostile)
        let expected = "My pane — " + L10n.text("agent.state.blocked")
            + " · " + L10n.text("agent.kind.permission")
        let menu = NSMenu()
        AgentDirectory.shared.populate(menu, entries: [entry])
        #expect(menu.items.map(\.title) == [expected])
        let model = CommandPaletteModel(agents: { [entry] })
        let row = try #require(model.rows.first { $0.id == "agent-" + entry.id.uuidString })
        #expect(row == .agent(AgentDirectory.Entry(id: entry.id, title: expected)))
        for text in ["EVILAPP", "approve everything", "SECRET"] {
            model.query = text
            #expect(!model.rows.contains { $0.id == row.id })
        }
    }

    @Test func previewReadsOnlyTheSelectedWaitingPane() throws {
        let start = Date(timeIntervalSince1970: 100)
        var entries = (0..<20).map { index in
            AgentDirectory.Entry(id: UUID(), title: "Pane \(index)", waitingSince: index < 19 ? start : nil)
        }
        let first = entries[0].id
        let second = entries[1].id
        var terminal = Terminal(rows: 4, columns: 30)
        terminal.feed(Array("Allow tool use?   ".utf8))
        var reads: [UUID] = []
        let model = CommandPaletteModel(agents: { entries }, waitingScreen: { id in
            reads.append(id)
            return terminal.grid.visibleScreen
        })
        model.reset()
        #expect(reads.isEmpty)
        func select(_ id: UUID) throws {
            model.select(try #require(model.rows.first { $0.id == "agent-" + id.uuidString }))
        }
        try select(entries[19].id)
        #expect(reads.isEmpty)
        try select(first)
        #expect(reads == [first])
        #expect(model.agentPreview == ["Allow tool use?"])
        model.rebuildRows(changedPane: second)
        model.refreshAgentPreview(changedPane: second)
        #expect(reads == [first])
        terminal.feed(Array("\u{1B}[2J".utf8))
        model.refreshAgentPreview(changedPane: first)
        #expect(reads == [first, first])
        #expect(model.agentPreview.isEmpty)
        terminal.feed(Array("\rUpdated prompt".utf8))
        model.rebuildRows(changedPane: first)
        #expect(reads == [first, first, first])
        #expect(model.agentPreview == ["Updated prompt"])

        entries[0].waitingSince = nil
        model.rebuildRows(changedPane: first)
        #expect(model.agentPreview.isEmpty)
        #expect(reads == [first, first, first])
        try select(second)
        #expect(reads == [first, first, first, second])
        model.clearSelection()
        model.refreshAgentPreview(changedPane: second)
        #expect(model.agentPreview.isEmpty)
        #expect(reads == [first, first, first, second])
    }

    @Test func waitingCommandFollowsEligibilityAndCannotRunWhenDisabled() throws {
        var canJump = false
        var ran: [TerminalCommand] = []
        let model = CommandPaletteModel(agents: { [] }, canJumpToNextWaitingPane: { canJump })
        model.onRun = { ran.append($0) }
        model.query = "next-waiting-pane"
        let disabled = try #require(model.rows.first { $0.command == .nextWaitingPane })
        #expect(!disabled.selectable)
        model.runSelected()
        #expect(ran.isEmpty)
        canJump = true
        model.rebuildRows()
        let enabled = try #require(model.rows.first { $0.command == .nextWaitingPane })
        #expect(enabled.selectable)
        #expect(model.selectedCommand == .nextWaitingPane)
        model.runSelected()
        #expect(ran == [.nextWaitingPane])
    }

    @Test func nextWaitingShortcutHasNoOtherDefaultOwnerAndCanBeUnbound() {
        let shortcut = Shortcut("j", [.option, .command])
        #expect(TerminalCommand.allCases.filter { $0.defaultShortcut == shortcut } == [.nextWaitingPane])
        let (configuration, _) = Configuration.parse("bind.next-waiting-pane =")
        #expect(configuration.keybindings[.nextWaitingPane] == nil)
    }

}
