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

/// The overlay over the canvas: the status rules' tooltips and the
/// directory and history suggestions at the prompt.
extension PaneShellIntegration {
    func updateShellOverlay(grid: Grid, canvas: CanvasTextColors) {
        guard let terminalView, let terminalRenderer else { return }
        let overlay = terminalView.shellOverlay
        if overlay.frame != terminalView.bounds { overlay.frame = terminalView.bounds }
        let metrics = terminalRenderer.pointMetrics
        let content = PaneFrameLoop.contentRect(in: terminalView.bounds.size, scale: 1,
            gridHeight: CGFloat(grid.rows) * metrics.cellHeight, topInset: topInset)
        let config = ConfigurationStore.shared.configuration
        // Everything the tooltip rows depend on. Rows' marks change only
        // with their lines, which `lineRevision` counts; history rows never
        // change, and `totalPushed` and `scrollOffset` place the window.
        var key = Hasher()
        key.combine(ObjectIdentifier(session))
        key.combine(knownStatusRevision)
        key.combine(config.commandStatusMarks)
        key.combine(grid.isAlternateScreenActive)
        key.combine(grid.scrollback.totalPushed)
        key.combine(grid.scrollback.count)
        key.combine(scrollOffset)
        key.combine(grid.rows)
        key.combine(grid.linesGeneration)
        key.combine(content.minX)
        key.combine(content.minY)
        key.combine(metrics.cellHeight)
        for row in 0..<grid.rows { key.combine(grid.lineRevision(row)) }
        let overlayKey = key.finalize()
        if overlayKey != statusOverlayKey {
            statusOverlayKey = overlayKey
            overlay.updateStatuses(statusRows(grid: grid, config: config, content: content, metrics: metrics))
        }
        showSuggestions(grid: grid, config: config, content: content, metrics: metrics, canvas: canvas)
    }

    /// The tooltips for the rules the renderer draws (`TerminalRenderer.rebuildMarks`).
    private func statusRows(
        grid: Grid, config: Configuration, content: CGRect, metrics: CellMetrics
    ) -> [ShellOverlayView.Status] {
        var rows: [ShellOverlayView.Status] = []
        if config.commandStatusMarks && !grid.isAlternateScreenActive {
            if statusSession !== session || statusRevision != knownStatusRevision {
                let records = session.commandRecords
                statusSession = session
                statusRevision = knownStatusRevision
                statusByRow.removeAll(keepingCapacity: true)
                for record in records.recordsInOrder {
                    if let status = record.exitStatus { statusByRow[record.promptRow] = status }
                }
            }
            let firstAbsolute = grid.scrollback.totalPushed - scrollOffset
            for row in 0..<grid.rows {
                let absolute = firstAbsolute + row
                guard let line = grid.line(atAbsoluteRow: absolute), line.mark.hasOutcome else { continue }
                let code =
                    statusByRow[absolute]
                    ?? (line.mark == .promptSucceeded ? 0 : line.mark == .promptInterrupted ? 130 : 1)
                let text =
                    code == 0
                    ? L10n.text("commandStatus.succeeded")
                    : code == 130
                        ? L10n.text("commandHistory.statusInterrupted")
                        : L10n.format("commandHistory.statusFailed", code)
                rows.append(.init(
                    rect: CGRect(
                        x: content.minX - TerminalLayout.statusRuleOffset,
                        y: content.minY + CGFloat(row) * metrics.cellHeight,
                        width: TerminalLayout.statusRuleWidth, height: metrics.cellHeight),
                    description: text))
            }
        }
        return rows
    }

    private func showSuggestions(
        grid: Grid, config: Configuration, content: CGRect, metrics: CellMetrics, canvas: CanvasTextColors
    ) {
        guard let terminalView else { return }
        let overlay = terminalView.shellOverlay
        let canSuggest =
            isFocusedPane && scrollOffset == 0 && host?.search.bar == nil && !knownCommandRunning
            && !grid.isAlternateScreenActive
        let completion = canSuggest && config.directoryCompletion ? session.directoryCompletion : nil
        let history = canSuggest && config.historySuggestions ? session.historySuggestion : nil
        let anchor = CGRect(x: content.minX + CGFloat(grid.cursor.column) * metrics.cellWidth,
            y: content.minY + CGFloat(grid.cursor.row) * metrics.cellHeight,
            width: metrics.cellWidth, height: metrics.cellHeight)
        overlay.showCompletion(completion, history: history, anchor: anchor,
            font: (host?.fontStyle ?? FontStyle()).font(
                ofSize: host?.fontSize ?? TerminalPaneViewController.defaultFontSize) as NSFont,
            baseline: metrics.baselineOffset, colors: canvas)
    }
}
