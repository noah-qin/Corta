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

/// What the sidebar and panel menus say: diagnostics, Git rows, the close confirmation.
extension CortaSpaceTests {
    @Test func resumeDetailsLiveInTheDiagnosticsSubmenu() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        let session = try #require(space.focusedSession)
        session.record.conversation = LocalConversation(kind: .claude)
        let panel = try #require(space.panels[ObjectIdentifier(session)])
        let fill = L10n.text("space.conversation.fillAgain")
        let menu = panel.makeMenu()
        #expect(!menu.items.contains { $0.title == fill }, "not on the panel menu's first level")
        let diagnostics = try #require(menu.items.first { $0.title == L10n.text("space.session.diagnostics") })
        #expect(diagnostics.submenu?.items.contains { $0.title == fill } == true)
        session.record.conversation = nil
        #expect(!panel.makeMenu().items.contains { $0.title == L10n.text("space.session.diagnostics") })
    }

    @Test func aSmallWindowIsNotGrownToSpaceMinimumAndKeepsItsFrame() throws {
        let (controller, host) = try makeWindow(limit: 6)
        defer { close(controller, host) }
        let window = try #require(controller.window)
        let small = NSRect(x: window.frame.minX, y: window.frame.minY, width: 480, height: 320)
        window.setFrame(small, display: true)
        let frame = window.frame
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        host.space.setActive(true)
        host.space.openProject(project)
        #expect(window.frame == frame, "a window below Space's minimum is not grown on entry")
        #expect(window.contentMinSize.width <= window.contentRect(forFrameRect: frame).width)
        host.space.newSession()
        #expect(window.frame == frame)
        host.space.setActive(false)
        #expect(window.frame == frame)
    }

    @Test func aWorktreeRowIsMarkedAndNamesItsMainRepositoryOnlyThere() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        space.newSession()
        let live = try #require(space.selectedProject)
        let worktree = live.sessions[0], main = live.sessions[1]
        space.gitFacts[worktree.id] = GitFacts(name: "side", detached: false, worktree: true,
            mainRepository: "/tmp/main-repo", changedFiles: 0, unchecked: false)
        space.gitFacts[main.id] = GitFacts(name: "main", detached: true, worktree: false, changedFiles: 0,
            unchecked: false)
        let row = try #require(space.gitRow(for: worktree.id))
        #expect(row.text == "side · " + L10n.text("space.git.worktree"))
        #expect(row.toolTip.contains(L10n.format("space.git.main", "/tmp/main-repo")))
        let plain = try #require(space.gitRow(for: main.id))
        #expect(plain.text == L10n.format("space.git.detached", "main"))
        #expect(!plain.toolTip.contains("/tmp/main-repo"))
        let reveal = L10n.text("space.worktree.reveal")
        let worktreeMenu = try #require(space.panels[ObjectIdentifier(worktree)]).makeMenu()
        #expect(worktreeMenu.items.contains { $0.title == reveal })
        let mainMenu = try #require(space.panels[ObjectIdentifier(main)]).makeMenu()
        #expect(!mainMenu.items.contains { $0.title == reveal }, "the main repository's own pane has no reveal")
    }

    @Test func theGitRowNamesUncheckedNewFilesAndShowsNothingForNoChanges() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let space = host.space
        let id = UUID()
        space.gitFacts[id] = GitFacts(name: "main", detached: false, worktree: false, changedFiles: 0,
                                      unchecked: false)
        let clean = try #require(space.gitRow(for: id))
        #expect(clean.text == "main")
        #expect(clean.toolTip == "main", "no changes: no mark and nothing about counts")
        space.gitFacts[id]?.changedFiles = 3
        let dirty = try #require(space.gitRow(for: id))
        #expect(dirty.text == "main · 3")
        #expect(dirty.toolTip.contains(L10n.format("space.git.dirty", 3)))
    }

    /// A maximized panel has left its split; hiding the panel it covers must
    /// not close that split into nothing and lose the maximized one's place.
    @Test func hidingACoveredPanelWhileAnotherIsMaximizedKeepsTheTreeWhole() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        space.newSession()
        space.newSession()
        let live = try #require(space.selectedProject)
        try #require(live.shown.count == 3)
        let big = live.shown[0], covered = live.shown[1]
        space.toggleMaximize(big)
        try #require(live.maximized === big)
        space.hide(covered)
        #expect(live.maximized == nil, "hiding under a maximized panel puts it back first")
        #expect(live.shown.count == 2)
        #expect(live.shown.contains(big))
        #expect(!live.shown.contains(covered))
        #expect(space.gridTree?.leafCount == 2)
        func splits(under view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] + $0.subviews.flatMap(splits) } ?? []
        }
        for split in space.gridTree.map({ splits(under: $0.root) }) ?? [] {
            #expect(split.subviews.count == 2, "no one-child split survives")
        }
        #expect(live.layout != nil, "the layout still captures the grid")
        // The same path when a covered session ends.
        space.toggleMaximize(big)
        try #require(live.maximized === big)
        space.removeSession(try #require(live.shown[1].pane))
        #expect(live.maximized == nil)
        #expect(space.gridTree?.leafCount == 1)
    }

    @Test func closingTheWindowSaysHowManySpaceSessionsEndHiddenOnesIncluded() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        space.newSession()
        space.newSession()
        let live = try #require(space.selectedProject)
        space.hide(live.shown[0])
        #expect(space.liveSessionCount == 3, "the hidden session counts")
        let alert = host.closeAlert(for: [], scope: L10n.text("close.scope.window"),
                                    spaceSessions: space.liveSessionCount)
        #expect(alert.informativeText.contains(L10n.format("close.running.space", 3)))
        #expect(!alert.informativeText.contains(L10n.text("close.running.single")),
                "idle Space shells are not 'a process still running'")
        let plain = host.closeAlert(for: [], scope: L10n.text("close.scope.window"))
        #expect(!plain.informativeText.contains(L10n.format("close.running.space", 3)))
        // Space's sessions ask even at a prompt, under `confirm-close`; a plain idle window does not.
        let original = ConfigurationStore.shared.configuration
        defer { _ = ConfigurationStore.shared.update { $0 = original } }
        _ = ConfigurationStore.shared.update { $0.confirmClose = true }
        #expect(host.needsCloseConfirmation(for: [], spaceSessions: space.liveSessionCount))
        #expect(!host.needsCloseConfirmation(for: []))
        _ = ConfigurationStore.shared.update { $0.confirmClose = false }
        #expect(!host.needsCloseConfirmation(for: [], spaceSessions: space.liveSessionCount))
    }
}
