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

extension ViewController {
    func updateShellOverlay(grid: Grid) {
        guard let terminalView, let terminalRenderer else { return }
        let overlay = terminalView.shellOverlay
        overlay.frame = terminalView.bounds
        let metrics = terminalRenderer.pointMetrics
        let content = Self.contentRect(in: terminalView.bounds.size, scale: 1,
            gridHeight: CGFloat(grid.rows) * metrics.cellHeight, topInset: topInset)
        let config = ConfigurationStore.shared.configuration
        let records = session.commandRecords.records
        var rows: [ShellOverlayView.Status] = []
        if config.commandStatusMarks && !grid.isAlternateScreenActive {
            let byRow = Dictionary(records.compactMap { record -> (Int, Int)? in
                guard let code = record.exitStatus else { return nil }
                return (record.promptRow, code)
            }, uniquingKeysWith: { _, last in last })
            let firstAbsolute = grid.scrollback.totalPushed - scrollOffset
            for row in 0..<grid.rows {
                let absolute = firstAbsolute + row
                guard let line = grid.line(atAbsoluteRow: absolute),
                    line.mark == .promptSucceeded || line.mark == .promptFailed || line.mark == .promptInterrupted else { continue }
                let code = byRow[absolute] ?? (line.mark == .promptSucceeded ? 0 : line.mark == .promptInterrupted ? 130 : 1)
                let text = code == 0 ? L10n.text("commandStatus.succeeded") : code == 130 ? L10n.text("commandHistory.statusInterrupted") : L10n.format("commandHistory.statusFailed", code)
                rows.append(.init(rect: CGRect(x: content.minX - 6, y: content.minY + CGFloat(row) * metrics.cellHeight, width: 2, height: metrics.cellHeight), code: code, description: text))
            }
        }
        overlay.updateStatuses(rows)
        let completion = config.directoryCompletion && isFocusedPane && scrollOffset == 0 && search.bar == nil && !session.isCommandRunning && !grid.isAlternateScreenActive ? session.directoryCompletion : nil
        let anchor = CGRect(x: content.minX + CGFloat(grid.cursor.column) * metrics.cellWidth,
            y: content.minY + CGFloat(grid.cursor.row) * metrics.cellHeight,
            width: metrics.cellWidth, height: metrics.cellHeight)
        overlay.showCompletion(completion, anchor: anchor,
            font: TerminalFont.primary(ofSize: fontSize, family: fontFamily) as NSFont,
            baseline: metrics.baselineOffset)
    }

    func handleDirectoryCompletionKey(_ event: NSEvent) -> Bool {
        guard let terminalView, let state = terminalView.shellOverlay.completion,
            !state.candidates.isEmpty else { return false }
        guard ConfigurationStore.shared.configuration.directoryCompletion,
            isFocusedPane, !session.isCommandRunning, !session.snapshot().isAlternateScreenActive,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            !terminalView.hasMarkedText() else {
            terminalView.shellOverlay.hideCompletion()
            return false
        }
        switch event.keyCode {
        case 48 where !event.modifierFlags.contains(.shift): // Tab only fills; Shift+Tab stays with the shell.
            acceptDirectoryCompletion(index: state.selectedIndex)
            return true
        case 123, 124:
            // Only horizontal arrows select; up/down retain shell history navigation.
            let next = event.keyCode == 124
            session.write(Array((next ? "\u{1b}[98~" : "\u{1b}[97~").utf8))
            return true
        case 53:
            session.write(Array("\u{1b}[96~".utf8))
            terminalView.shellOverlay.hideCompletion()
            return true
        default:
            terminalView.shellOverlay.hideCompletion()
            return false
        }
    }

    func acceptDirectoryCompletion(index: Int) {
        guard let terminalView, let state = terminalView.shellOverlay.completion,
            state.candidates.indices.contains(index), !session.isCommandRunning,
            isFocusedPane, !session.snapshot().isAlternateScreenActive else { return }
        // Only fixed widget sequences, never bytes originating from PTY output.
        let delta = index - state.selectedIndex
        let movement = delta < 0 ? "\u{1b}[97~" : "\u{1b}[98~"
        session.write(Array((String(repeating: movement, count: abs(delta)) + "\u{1b}[99~").utf8))
        terminalView.shellOverlay.hideCompletion()
        terminalView.window?.makeFirstResponder(terminalView)
    }
}
