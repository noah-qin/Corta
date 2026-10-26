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

/// ⌘↑ / ⌘↓ stop at every prompt mark, including OSC 1337 SetMark, which
/// marks a row without a shell command behind it (#411).
@MainActor
struct CommandJumpTests {
    private final class Pane: ViewController {
        override func viewDidLoad() {}
    }

    @Test func setMarkIsANavigationStopWithoutCommandRecords() async throws {
        let pane = Pane()
        pane.view = NSView()
        pane.session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), size: TerminalSize(rows: 10, columns: 40),
            workingDirectory: "/")
        pane.session.start()
        defer { pane.session.stop() }
        let marker = UUID().uuidString
        pane.session.write(Array(("\u{1B}]1337;SetMark\u{1B}\\mark\n" + String(repeating: "x\n", count: 30)
            + "\u{1B}]2;" + marker + "\u{1B}\\\n").utf8))
        let deadline = SuspendingClock.now + .seconds(5)
        while pane.session.windowTitle != marker, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(pane.session.windowTitle == marker)
        #expect(pane.session.commandRecords.records.isEmpty)
        let grid = pane.session.snapshot()
        let markRow = try #require(grid.promptRows.first)
        pane.shell.jumpToPreviousCommand(nil)
        #expect(pane.scrollOffset > 0)
        #expect(ScrollbackCoordinates.viewportTopRow(
            totalPushed: grid.scrollback.totalPushed, scrollOffset: pane.scrollOffset) == markRow)
        pane.shell.jumpToNextCommand(nil)
        #expect(pane.scrollOffset > 0, "no later mark: the view stays put")
    }
}
