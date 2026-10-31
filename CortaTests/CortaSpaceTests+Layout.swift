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
import Darwin
import Testing
@testable import Corta

extension CortaSpaceTests {
    @Test func aDropOnAnEdgeSplitsThatPanelThere() throws {
        let (controller, host) = try makeWindow(limit: 6)
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        let live = try #require(space.selectedProject)
        let first = live.sessions[0]
        space.newSession()
        let second = live.sessions[1]
        space.hide(second)
        host.view.layoutSubtreeIfNeeded()
        #expect(live.shown == [first])
        host.view.layoutSubtreeIfNeeded()
        let target = try #require(space.panel(for: first))
        try #require(space.canDrop(second, on: target, edge: .top),
                     "target: \(target.frame), minimum: \(space.minimumPanelSize), grid: \(space.gridArea)")
        space.drop(second, on: target, edge: .top)
        #expect(live.shown == [second, first], "the top half comes first")
        let split = try #require(space.gridTree?.root as? NSSplitView)
        #expect(!split.isVertical)
        // Closing a panel leaves its neighbour the space; dropping on the
        // neighbour's edge puts a session back there.
        space.hide(second)
        host.view.layoutSubtreeIfNeeded()
        #expect(live.shown == [first])
        space.drop(second, on: target, edge: .top)
        #expect(live.shown == [second, first])
    }

    @Test func aPlacementUndoesToTheGridBeforeIt() throws {
        let (controller, host) = try makeWindow(limit: 6)
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        space.newSession()
        let live = try #require(space.selectedProject)
        let hidden = live.sessions[1]
        space.hide(hidden)
        let before = live.layout
        let undo = try #require(controller.window?.undoManager)
        // Separate UI actions belong to separate event groups. This test
        // drives them synchronously, so it supplies the Show action's group.
        undo.removeAllActions()
        undo.beginUndoGrouping()
        space.show(hidden)
        undo.endUndoGrouping()
        #expect(live.shown.contains(hidden))
        #expect(undo.canUndo)
        undo.undo()
        #expect(live.layout == before, "the grid as it was")
        #expect(!live.shown.contains(hidden))
        #expect(kill(try #require(hidden.pane?.session).pty.processIdentifier, 0) == 0, "still running")
        undo.redo()
        #expect(live.shown.contains(hidden))
    }

}
