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

/// Entering and leaving Space: the window, the terminal tree, the first-run note.
extension CortaSpaceTests {
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
        #expect(window.frame == frame, "Space shows in the window's own frame")
        for _ in 0..<3 {
            host.space.setActive(false)
            #expect(window.frame == frame, "and leaving it changes nothing either")
            #expect(host.terminalTree.leaves == terminalLeaves)
            #expect(terminalLeaves.allSatisfy { $0.window === window })
            #expect(spacePane.view.window == nil)
            host.space.setActive(true)
            #expect(window.frame == frame)
            #expect(spacePane.view.window === window)
            #expect(terminalLeaves.allSatisfy { $0.window == nil })
        }
        for session in terminalSessions + [try #require(spacePane.session)] {
            #expect(kill(session.pty.processIdentifier, 0) == 0)
        }
        #expect(window.title == project.lastPathComponent)
    }

    @Test func theIntroductionShowsOnceAndIsRememberedInSpaceState() throws {
        let previous = CortaSpaceController.showsIntroduction
        CortaSpaceController.showsIntroduction = true
        defer { CortaSpaceController.showsIntroduction = previous }
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        var shown: [String] = []
        host.space.presentAlert = { alert, _, done in
            shown.append(alert.messageText)
            done(.alertFirstButtonReturn)
        }
        host.space.setActive(true)
        #expect(shown == [L10n.text("space.introduction.title")])
        host.space.setActive(false)
        host.space.setActive(true)
        #expect(shown.count == 1, "a second visit shows nothing")
        host.space.saveNow()
        #expect(SpaceStore.standard.load().introductionShown == true)
    }
}
