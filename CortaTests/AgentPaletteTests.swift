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
}
