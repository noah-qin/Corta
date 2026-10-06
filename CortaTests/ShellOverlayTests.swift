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

@MainActor struct ShellOverlayTests {
    @Test func statusGutterHasTextOutsideTerminalCells() {
        let overlay = ShellOverlayView()
        let rect = CGRect(x: 7, y: 60, width: 2, height: 20)
        let message = L10n.text("commandHistory.statusInterrupted")
        overlay.updateStatuses([.init(rect: rect, description: message)])
        #expect(rect.maxX < TerminalLayout.insets.left)
        #expect(overlay.view(overlay, stringForToolTip: 0, point: CGPoint(x: 8, y: 65), userData: nil) == message)
        overlay.updateStatuses([])
        #expect(overlay.view(overlay, stringForToolTip: 0, point: CGPoint(x: 8, y: 65), userData: nil).isEmpty)
    }
    @Test func settingsRoundTripAndInterruptedHistoryDescription() {
        let (configuration, unknown) = Configuration.parse("directory-completion = false\ncommand-status-marks = false")
        #expect(unknown.isEmpty)
        #expect(!configuration.directoryCompletion && !configuration.commandStatusMarks)
        #expect(Configuration.parse(configuration.serialized()).configuration == configuration)
        var terminal = Terminal(rows: 10, columns: 60)
        terminal.feed(Array("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}sleep 10\r\n\u{1b}]133;C\u{7}\u{1b}]133;D;130\u{7}".utf8))
        let model = CommandHistoryModel()
        model.refresh(records: terminal.commandRecords.records, grid: terminal.grid, directory: nil)
        #expect(model.rows.first?.statusSymbolName == "minus.circle")
        #expect(model.rows.first?.statusDescription.contains("130") == true)
    }
}
