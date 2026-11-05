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

    @Test func programTextCannotEnterMenuOrPalette() throws {
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
