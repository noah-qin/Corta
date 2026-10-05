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

import Cocoa
import CortaTerminal

/// Keyboard pane resizing and the running-job close confirmation — both
/// window-level: a divider belongs to two panes, and a close asks every
/// session in the subtree.
extension SplitViewController {
    // MARK: - Resizing panes from the keyboard

    @objc func growPaneHorizontally(_ sender: Any?) { resizeFocusedPane(vertical: true, steps: 1) }
    @objc func shrinkPaneHorizontally(_ sender: Any?) { resizeFocusedPane(vertical: true, steps: -1) }
    @objc func growPaneVertically(_ sender: Any?) { resizeFocusedPane(vertical: false, steps: 1) }
    @objc func shrinkPaneVertically(_ sender: Any?) { resizeFocusedPane(vertical: false, steps: -1) }

    /// Moves the focused pane's divider by whole cells, the unit the user
    /// adjusts; the constraints stop it at a minimum.
    ///
    /// - Parameter vertical: move a vertical divider (change widths), owned
    ///   by the nearest ancestor split that way.
    private func resizeFocusedPane(vertical: Bool, steps: CGFloat) {
        guard let focusedPane else { return }
        var child: NSView = focusedPane.view
        var node = child.superview as? NSSplitView
        while let current = node, current.isVertical != vertical {
            child = current
            node = current.superview as? NSSplitView
        }
        guard let split = node, let index = split.subviews.firstIndex(of: child),
            split.subviews.count == 2
        else { return }

        // A failed pane (no Metal 4) has no cell size to step by.
        guard let metrics = focusedPane.terminalRenderer?.pointMetrics else { return }
        let step = vertical ? metrics.cellWidth : metrics.cellHeight
        // Two children per node, so the divider sits at the first's extent,
        // measured from the top (flipped).
        let first = split.subviews[0].frame
        let position = vertical ? first.width : first.height
        let direction: CGFloat = index == 0 ? 1 : -1
        split.setPosition(position + direction * steps * step, ofDividerAt: 0)
        deliverPaneSizes()
    }

    /// Halves every node, back to a fresh split's layout.
    @objc func equalizePanes(_ sender: Any?) {
        equalize(view.subviews.first)
        deliverPaneSizes()
    }

    private func equalize(_ subtree: NSView?) {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else { return }
        for child in split.subviews { equalize(child) }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition(axis / 2, ofDividerAt: 0)
    }

    /// Deliver now, not after the debounce, or the grid lags each press.
    private func deliverPaneSizes() {
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
    }

    // MARK: - Closing with something still running

    var panesWithRunningJobs: [ViewController] {
        panes.filter { $0.session?.hasForegroundJob == true }
    }

    /// Asks before discarding work; true to proceed. Checks the pty's
    /// foreground process group, not output, so a bare prompt never asks.
    func confirmClose(of running: [ViewController], scope: String) -> Bool {
        guard ConfigurationStore.shared.configuration.confirmClose, !running.isEmpty else {
            return true
        }
        let names = running.compactMap { $0.session?.foregroundProcessName }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("close.running.title", scope)
        alert.informativeText =
            names.isEmpty
            ? L10n.text("close.running.single")
            : L10n.format("close.running.multiple", ListFormatter.localizedString(byJoining: Array(Set(names)).sorted()))
        alert.addButton(withTitle: L10n.text("close.running.closeAnyway"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        // Keep the destructive action explicit; Return defaults to Cancel.
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}


extension SplitViewController {
    @objc func selectPreviousCortaTab(_ sender: Any?) { selectAdjacentTab(offset: -1) }
    @objc func selectNextCortaTab(_ sender: Any?) { selectAdjacentTab(offset: 1) }

    func selectAdjacentTab(offset: Int) {
        guard let window = view.window, let tabs = window.tabbedWindows,
              let index = tabs.firstIndex(of: window), tabs.count > 1 else { return }
        let target = tabs[(index + offset + tabs.count) % tabs.count]
        window.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    @objc func renameCurrentTab(_ sender: Any?) {
        (view.window?.windowController as? TerminalWindowController)?.beginTabRename()
    }

    func setCustomTabTitle(_ value: String) {
        guard let controller = view.window?.windowController as? TerminalWindowController else { return }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.customTabTitle = title.isEmpty ? nil : String(title.prefix(200))
        applyWindowTitle()
    }
}
