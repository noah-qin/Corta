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

/// The grid's rules and the saved file, without a window.
struct SpaceGridTests {
    private let minimum = CGSize(width: 500, height: 300)

    @Test func aDropNearAnEdgeMeansThatEdge() {
        let size = CGSize(width: 400, height: 200)
        #expect(SpaceGrid.edge(at: CGPoint(x: 20, y: 100), in: size) == .left)
        #expect(SpaceGrid.edge(at: CGPoint(x: 390, y: 100), in: size) == .right)
        #expect(SpaceGrid.edge(at: CGPoint(x: 200, y: 190), in: size) == .top, "y is up")
        #expect(SpaceGrid.edge(at: CGPoint(x: 200, y: 10), in: size) == .bottom)
        #expect(SpaceGrid.edge(at: CGPoint(x: 200, y: 100), in: size) == nil, "the middle replaces")
        #expect(SpaceGrid.edge(at: .zero, in: .zero) == nil)
    }

    @Test func aSplitLeavesBothHalvesTheMinimum() {
        let gap = SpaceGrid.dividerThickness
        #expect(SpaceGrid.canSplit(CGSize(width: 1000 + gap, height: 100), vertical: true, minimum: minimum))
        #expect(!SpaceGrid.canSplit(CGSize(width: 999 + gap, height: 900), vertical: true, minimum: minimum))
        #expect(SpaceGrid.automaticSplit(of: CGSize(width: 1200, height: 700), minimum: minimum) == true)
        #expect(SpaceGrid.automaticSplit(of: CGSize(width: 600, height: 700), minimum: minimum) == false)
        #expect(SpaceGrid.automaticSplit(of: CGSize(width: 600, height: 400), minimum: minimum) == nil)
    }

    @Test func theLeastRecentlyUsedIsNeverTheFocused() {
        let used: [String: UInt64] = ["a": 1, "b": 5, "c": 3]
        #expect(SpaceGrid.leastRecentlyUsed(["a", "b", "c"], recency: { used[$0]! }, protected: "a") == "c")
        #expect(SpaceGrid.leastRecentlyUsed(["a", "b", "c"], recency: { used[$0]! }, protected: nil) == "a")
        #expect(SpaceGrid.leastRecentlyUsed(["a"], recency: { used[$0]! }, protected: "a") == "a")
    }

    @Test func aSavedLayoutKeepsOnlyRealSessionsOnce() {
        let layout = SpaceLayoutRecord.split(
            vertical: true, fraction: 2, first: .panel(0),
            second: .split(vertical: false, fraction: 0.3, first: .panel(0), second: .panel(9)))
        #expect(layout.validated(sessionCount: 3) == .panel(0), "a split that loses a side is its other side")
        let wide = SpaceLayoutRecord.split(vertical: true, fraction: 2, first: .panel(0), second: .panel(1))
        #expect(wide.validated(sessionCount: 2)
            == .split(vertical: true, fraction: 0.9, first: .panel(0), second: .panel(1)))
        var seven = SpaceLayoutRecord.panel(0)
        for index in 1...7 { seven = .split(vertical: true, fraction: 0.5, first: seven, second: .panel(index)) }
        #expect((seven.validated(sessionCount: 8)?.panels.count ?? 0) <= SpaceGrid.maximumPanels)
    }

    @Test func panelSizesFollowTheSplits() {
        let layout = SpaceLayoutRecord.split(
            vertical: false, fraction: 0.4, first: .panel(2),
            second: .split(vertical: true, fraction: 0.5, first: .panel(0), second: .panel(1)))
        let gap = SpaceGrid.dividerThickness
        let sizes = layout.panelSizes(in: CGSize(width: 1010, height: 610))
        #expect(sizes[2] == CGSize(width: 1010, height: 244))
        #expect(sizes[0] == CGSize(width: 505, height: 610 - 244 - gap))
        #expect(sizes[1] == CGSize(width: 1010 - 505 - gap, height: 610 - 244 - gap))
    }

    @Test func aHandEditedFileIsBoundedFieldByField() {
        var sessions = (1...40).map { SpaceSessionRecord(number: $0, directory: "/tmp") }
        sessions[0].directory = "relative/path"
        sessions[1].ssh = SSHTarget(host: "-oProxyCommand=evil")
        let project = SpaceProjectRecord(
            path: "/work", sessions: sessions, layout: .split(vertical: true, fraction: 0.5, first: .panel(3),
                                                               second: .panel(99)), nextNumber: 2)
        let state = SpaceState(
            projects: [project, SpaceProjectRecord(path: "relative"), SpaceProjectRecord(path: "/work")],
            selectedProject: "/elsewhere"
        ).validated()
        #expect(state.projects.count == 1)
        #expect(state.selectedProject == "/work")
        let valid = state.projects[0]
        #expect(valid.sessions.count == SpaceState.maximumSessions)
        #expect(valid.sessions[0].directory == nil)
        #expect(valid.sessions[1].ssh == nil, "an option-shaped host is refused")
        #expect(valid.layout == .panel(3))
        #expect(valid.nextNumber == 33)
    }

    @Test func aRemoteDropIsTakenOnlyOnItsOwnHost() throws {
        let ours = SSHTarget(host: "Build.Example.com", user: "deploy", port: 2222)
        func path(_ text: String) -> String? {
            guard let url = URL(string: text), let host = url.host(percentEncoded: false) else { return nil }
            return PaneRemote.remotePath(of: url, host: host, matching: ours)
        }
        #expect(path("sftp://deploy@build.example.com:2222/var/log/app.log") == "/var/log/app.log")
        #expect(path("sftp://build.example.com/srv/my%20file") == "/srv/my file", "no user or port: the host decides")
        #expect(path("sftp://other.example.com/var/log/app.log") == nil, "another host")
        #expect(path("sftp://root@build.example.com/etc/passwd") == nil, "another user")
        #expect(path("sftp://build.example.com:22/tmp/x") == nil, "another port")
        #expect(path("sftp://build.example.com/tmp/evil%0Arm%20-rf%20~") == nil, "a newline is refused, not cleaned")
        #expect(path("sftp://build.example.com/tmp/%1B%5D52;c;AAAA%07") == nil, "so is an escape")
        #expect(path("https://build.example.com/tmp/x") == nil, "only sftp")
        let six = SSHTarget(host: "2001:db8::1")
        let url = try #require(URL(string: "sftp://[2001:db8::1]/home/a"))
        #expect(PaneRemote.remotePath(of: url, host: try #require(url.host(percentEncoded: false)), matching: six)
            == "/home/a")
    }

    @Test @MainActor func aRemoteDragIsKnownOnlyAsAFilePromiseInFlight() throws {
        let url = try #require(URL(string: "sftp://deploy@build.example.com/var/log/app.log"))
        let promise = NSPasteboard.PasteboardType(try #require(NSFilePromiseReceiver.readableDraggedTypes.first))
        SFTPRemoteDrag.begin(url)
        defer { SFTPRemoteDrag.end() }
        #expect(SFTPRemoteDrag.url(forPasteboardTypes: [promise]) == url)
        #expect(SFTPRemoteDrag.url(forPasteboardTypes: [.string, .URL]) == nil, "not a drag of the browser's")
        SFTPRemoteDrag.end()
        #expect(SFTPRemoteDrag.url(forPasteboardTypes: [promise]) == nil, "a finished drag is not reused")
    }

    @Test func arrangingPicksWhichAxisEachLineOwns() throws {
        let columns = try #require(SpaceLayoutRecord.arranged(Array(0..<6), inColumns: true))
        guard case .split(let vertical, _, let first, _) = columns, case .split(let inner, _, _, _) = first else {
            Issue.record("six panels split")
            return
        }
        #expect(vertical, "columns side by side")
        #expect(!inner, "each column a stack, with its own heights")
        #expect(columns.panels == [0, 1, 2, 3, 4, 5])
        let rows = try #require(SpaceLayoutRecord.arranged(Array(0..<5), inColumns: false))
        guard case .split(let stacked, _, _, _) = rows else {
            Issue.record("five panels split")
            return
        }
        #expect(!stacked, "rows one above the other")
        #expect(rows.panels.count == 5)
        #expect(SpaceLayoutRecord.arranged([3], inColumns: true) == .panel(3))
        #expect(SpaceLayoutRecord.arranged([], inColumns: true) == nil)
    }

    @Test func aSessionNameIsOneBoundedLine() {
        #expect(SpaceSessionRecord.cleanName("  Frontend \u{1B}[31mbuild\n ") == "Frontend [31mbuild")
        #expect(SpaceSessionRecord.cleanName("   ") == nil)
        #expect(SpaceSessionRecord.cleanName(String(repeating: "x", count: 200))?.count
            == SpaceSessionRecord.maximumNameLength)
    }

    @Test @MainActor func theStoreRoundTripsAndForgetsMissingFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceStore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpaceStore(directory: directory)
        #expect(store.load() == SpaceState())
        let state = SpaceState(projects: [
            SpaceProjectRecord(
                path: "/present", sessions: [SpaceSessionRecord(number: 1, directory: "/gone")], layout: .panel(0)),
            SpaceProjectRecord(path: "/absent"),
        ], selectedProject: "/absent")
        store.save(state)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let loaded = store.load(isDirectory: { $0 == "/present" })
        #expect(loaded.projects.map(\.path) == ["/present"])
        #expect(loaded.projects[0].sessions[0].directory == nil)
        #expect(loaded.selectedProject == "/present")
        // A newer format is neither read nor written over.
        try Data(#"{"version":99,"projects":[]}"#.utf8).write(to: store.fileURL)
        store.save(state)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8).contains("99"))
        #expect(store.load() == SpaceState())
    }
}

/// Space in a real window, with real shells.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct CortaSpaceTests {
    /// A window, a fresh Space file and the given panel limit. Space fills
    /// the screen, which holds a 2 × 2 grid.
    func makeWindow(limit: Int = 4) throws -> (TerminalWindowController, SplitViewController) {
        try? FileManager.default.removeItem(at: SpaceStore.standard.fileURL)
        _ = ConfigurationStore.shared.update { $0.spacePanelLimit = limit }
        let controller = TerminalWindowController(setup: .init())
        let host = try #require(controller.contentViewController as? SplitViewController)
        controller.showWindow(nil)
        return (controller, host)
    }

    func close(_ controller: TerminalWindowController, _ host: SplitViewController) {
        host.teardown()
        controller.window?.close()
        _ = ConfigurationStore.shared.update { $0.spacePanelLimit = 4 }
        try? FileManager.default.removeItem(at: SpaceStore.standard.fileURL)
    }

    func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func switchingModesKeepsTheTerminalTreeAndEveryProcess() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let window = try #require(controller.window)
        host.splitRight(nil)
        let terminalLeaves = host.terminalTree.leaves
        let terminalSessions = host.panes.compactMap(\.session)
        let frame = window.frame
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        host.space.setActive(true)
        host.space.openProject(project)
        let spacePane = try #require(host.focusedPane)
        #expect(host.space.owns(spacePane))
        #expect(spacePane.inheritedWorkingDirectory == project.standardizedFileURL.resolvingSymlinksInPath().path)
        let screen = try #require(window.screen?.visibleFrame)
        #expect(window.frame == screen, "Space takes the screen")
        for _ in 0..<3 {
            host.space.setActive(false)
            #expect(window.frame == frame, "and gives the terminal its frame back")
            #expect(host.terminalTree.leaves == terminalLeaves)
            #expect(terminalLeaves.allSatisfy { $0.window === window })
            #expect(spacePane.view.window == nil)
            host.space.setActive(true)
            #expect(window.frame == screen)
            #expect(spacePane.view.window === window)
            #expect(terminalLeaves.allSatisfy { $0.window == nil })
        }
        for session in terminalSessions + [try #require(spacePane.session)] {
            #expect(kill(session.pty.processIdentifier, 0) == 0)
        }
        #expect(window.title == project.lastPathComponent)
    }

    @Test func newSessionsSplitUntilTheLimitThenReplaceTheLeastRecentlyUsed() throws {
        let (controller, host) = try makeWindow(limit: 2)
        defer { close(controller, host) }
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let space = host.space
        space.setActive(true)
        space.openProject(project)
        space.newSession()
        let live = try #require(space.selectedProject)
        let first = live.sessions[0], second = live.sessions[1]
        #expect(live.shown == [first, second])
        #expect(space.gridTree?.root is NSSplitView)
        space.focus(first)
        // At the limit: "second" is the least recently used, and the third
        // takes its place.
        space.newSession()
        let third = live.sessions[2]
        #expect(live.shown == [first, third])
        #expect(second.pane?.view.window == nil)
        #expect(kill(try #require(second.pane?.session).pty.processIdentifier, 0) == 0)
        // Showing an on-screen session moves focus and nothing else.
        let root = space.gridTree?.root
        space.show(first)
        #expect(space.gridTree?.root === root)
        #expect(host.focusedPane === first.pane)
        // A drop on a panel's middle swaps two on screen; the tree stays.
        space.drop(third, on: try #require(space.panel(for: first)), edge: nil)
        #expect(live.shown == [third, first])
        #expect(space.gridTree?.root === root)
        // A hidden session dropped in the middle takes that panel's place,
        // and the other panel does not move.
        let kept = try #require(first.pane?.view.window)
        space.drop(second, on: try #require(space.panel(for: third)), edge: .left)
        #expect(live.shown == [second, first], "at the limit an edge drop replaces")
        #expect(first.pane?.view.window === kept)
    }

    @Test func hidingFillingAndEndingKeepTheRestRunning() throws {
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
        let hidden = live.shown[1]
        space.hide(hidden)
        #expect(live.shown.count == 2)
        #expect(hidden.pane?.view.window == nil)
        #expect(kill(try #require(hidden.pane?.session).pty.processIdentifier, 0) == 0)
        let filled = live.shown[0]
        space.toggleMaximize(filled)
        #expect(live.maximized === filled)
        #expect(live.shown.count == 2, "the filled panel still counts as shown")
        host.toggleZoomPane(nil)
        #expect(live.maximized == nil)
        #expect(space.gridTree?.leafCount == 2)
        space.removeSession(try #require(filled.pane))
        #expect(!live.sessions.contains(filled))
        #expect(filled.pane == nil)
        #expect(host.panes.count == 3, "the terminal mode's pane and two sessions remain")
    }

    @Test func projectsKeepTheirOwnSessionsAndAreSaved() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        let first = try makeProject(), second = try makeProject()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let space = host.space
        space.setActive(true)
        space.openProject(first)
        space.newSession()
        let projectA = try #require(space.selectedProject)
        space.openProject(second)
        let projectB = try #require(space.selectedProject)
        #expect(space.projects.count == 2)
        #expect(projectA.sessions.allSatisfy { $0.pane?.view.window == nil })
        #expect(projectB.shown.count == 1)
        #expect(projectA.tree != nil, "a project keeps its grid while another shows")
        space.openProject(first)
        #expect(space.selectedProject === projectA)
        #expect(space.projects.count == 2, "opening a folder again selects it")
        space.rename(projectA.sessions[0], to: "  Agent A  ")
        #expect(SpaceSessionPresentation(session: projectA.sessions[0]).title == "Agent A")
        space.saveNow()
        let saved = SpaceStore.standard.load()
        #expect(saved.projects[0].sessions[0].name == "Agent A")
        #expect(saved.projects.map(\.path) == [projectA.path, projectB.path])
        #expect(saved.projects[0].sessions.count == 2)
        #expect(saved.projects[0].layout?.panels.count == 2)
        #expect(saved.selectedProject == projectA.path)
        // Space's state is not the window arrangement's; only its mode is.
        #expect(controller.restorableState?.isSpace == true)
        let layout = try #require(controller.restorableState?.layout)
        guard case .pane = layout else {
            Issue.record("the saved arrangement is the terminal mode's single pane, not Space's grid")
            return
        }
    }

    @Test func aSecondWindowBringsTheFirstSpaceForward() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        host.space.setActive(true)
        let other = TerminalWindowController(setup: .init())
        let otherHost = try #require(other.contentViewController as? SplitViewController)
        other.showWindow(nil)
        defer { otherHost.teardown(); other.window?.close() }
        otherHost.space.setActive(true)
        #expect(!otherHost.space.isActive)
        #expect(host.space.isActive)
    }

}
