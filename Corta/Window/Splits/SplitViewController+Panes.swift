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

    @objc func growPaneHorizontally(_: Any?) { resizeFocusedPane(vertical: true, steps: 1) }
    @objc func shrinkPaneHorizontally(_: Any?) { resizeFocusedPane(vertical: true, steps: -1) }
    @objc func growPaneVertically(_: Any?) { resizeFocusedPane(vertical: false, steps: 1) }
    @objc func shrinkPaneVertically(_: Any?) { resizeFocusedPane(vertical: false, steps: -1) }

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
        (split as? PaneSplitView)?.isUserPositioned = true
        deliverPaneSizes()
    }

    /// Halves every node, back to a fresh split's layout.
    @objc func equalizePanes(_: Any?) {
        // Zoomed, nothing is equalized, and unzooming puts the dividers back:
        // they stay the user's.
        if zoomedPane == nil {
            for node in tree.nodes { (node as? PaneSplitView)?.isUserPositioned = false }
        }
        equalize(view.subviews.first)
        deliverPaneSizes()
        // Halving is not equal shares in a row of three: with its marks gone, the
        // setting's own layout is what Equalize means.
        balancePanesIfConfigured()
    }

    private func equalize(_ subtree: NSView?) {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else { return }
        for child in split.subviews { equalize(child) }
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        split.setPosition((axis - split.dividerThickness) / 2, ofDividerAt: 0)
    }

    /// Deliver now, not after the debounce, or the grid lags each press.
    private func deliverPaneSizes() {
        notePanesRearranged()
        view.layoutSubtreeIfNeeded()
        for pane in panes {
            pane.resizeSessionToFitView()
            pane.endLiveResize()
        }
    }

    // MARK: - Closing with something still running

    var panesWithRunningJobs: [TerminalPaneViewController] {
        panes.filter(\.hasSessionRequiringCloseConfirmation)
    }

    /// Whether closing `running` asks first: something is running and
    /// `confirm-close` is on. Foreground jobs and direct remote launchers
    /// count; a bare local shell prompt does not.
    func needsCloseConfirmation(for running: [TerminalPaneViewController]) -> Bool {
        ConfigurationStore.shared.configuration.confirmClose && !running.isEmpty
    }

    /// Asks before discarding work, as a sheet on `window`, and reports
    /// whether to proceed — at once, true, when nothing needs asking.
    /// `window` nil asks app-modally.
    func confirmClose(
        of running: [TerminalPaneViewController], scope: String, in window: NSWindow?,
        replacingSession: Bool = false,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard needsCloseConfirmation(for: running) else {
            completion(true)
            return
        }
        closeAlert(for: running, scope: scope, replacingSession: replacingSession)
            .present(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
    }

    /// The "still running" alert; Return is Cancel.
    func closeAlert(
        for running: [TerminalPaneViewController], scope: String, replacingSession: Bool = false
    ) -> NSAlert {
        let names = running.compactMap { pane in
            pane.session?.foregroundProcessName
                ?? (pane.remote.childIsLiveLauncher
                    ? pane.launchedCommand.map { ($0.executable as NSString).lastPathComponent }
                    : nil)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = replacingSession
            ? L10n.text("connect.replaceRunning.title") : L10n.format("close.running.title", scope)
        alert.informativeText =
            names.isEmpty
            ? L10n.text("close.running.single")
            : L10n.format(
                "close.running.multiple", ListFormatter.localizedString(byJoining: Array(Set(names)).sorted()))
        let action = replacingSession ? "connect.replaceRunning.button" : "close.running.closeAnyway"
        alert.addButton(withTitle: L10n.text(action))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        // Keep the destructive action explicit; Return defaults to Cancel.
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        alert.window.identifier = Self.closeConfirmationIdentifier
        return alert
    }

    /// The "still running" alert's window, so a quit can tell that a close
    /// is already being asked about.
    static let closeConfirmationIdentifier = NSUserInterfaceItemIdentifier("dev.noahqin.Corta.closeConfirmation")
}

extension SplitViewController {
    @objc func selectPreviousCortaTab(_: Any?) { selectAdjacentTab(offset: -1) }
    @objc func selectNextCortaTab(_: Any?) { selectAdjacentTab(offset: 1) }
    @objc func selectCortaTab1(_: Any?) { tab?.controller?.selectTab(number: 1) }
    @objc func selectCortaTab2(_: Any?) { tab?.controller?.selectTab(number: 2) }
    @objc func selectCortaTab3(_: Any?) { tab?.controller?.selectTab(number: 3) }
    @objc func selectCortaTab4(_: Any?) { tab?.controller?.selectTab(number: 4) }
    @objc func selectCortaTab5(_: Any?) { tab?.controller?.selectTab(number: 5) }
    @objc func selectCortaTab6(_: Any?) { tab?.controller?.selectTab(number: 6) }
    @objc func selectCortaTab7(_: Any?) { tab?.controller?.selectTab(number: 7) }
    @objc func selectCortaTab8(_: Any?) { tab?.controller?.selectTab(number: 8) }
    @objc func selectLastCortaTab(_: Any?) { tab?.controller?.selectTab(number: 9) }

    func selectAdjacentTab(offset: Int) {
        tab?.controller?.selectAdjacentTab(offset: offset)
    }

    @objc func renameCurrentTab(_: Any?) {
        tab?.controller?.beginTabRename()
    }
}

extension SplitViewController {
    /// Spring only visible, user-created splits; restore and hidden windows
    /// remain immediate. Accessibility's Reduce Motion preference wins.
    func animateSplit(_ node: NSSplitView, newPane pane: TerminalPaneViewController) {
        let axis = node.isVertical ? node.bounds.width : node.bounds.height
        if view.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let minimum = pane.minimumContentSize
            let extent = node.isVertical ? minimum.width : minimum.height
            let end = (axis - node.dividerThickness) / 2
            let start = max(end, axis - extent - node.dividerThickness)
            splitTransition.start(node: node, from: start, to: end, revealing: pane.view) { [weak self] in
                guard let self else { return }
                self.view.layoutSubtreeIfNeeded()
                for child in self.panes {
                    child.resizeSessionToFitView(coalesce: false)
                    child.paneHeader.refresh()
                }
            }
        }
    }
}

extension SplitViewController {
    /// Resize once to the settled geometry before revealing it. Keeping the
    /// old grid throughout the animation caused a second visible reflow at
    /// its end, especially at the right and bottom edges.
    func prepareClosingGrid(node: NSSplitView, start: CGFloat, end: CGFloat, closing: TerminalPaneViewController) {
        let split = node as? PaneSplitView
        let thickness = node.dividerThickness
        isRearrangingPanes = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        split?.transitionDividerThickness = 0
        node.setPosition(end, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        isRearrangingPanes = false
        for child in panes where child !== closing { child.resizeSessionToFitView(coalesce: false) }
        isRearrangingPanes = true
        split?.transitionDividerThickness = thickness
        node.setPosition(start, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        CATransaction.commit()
        // start() sets isRunning before the next layout can request a resize.
        isRearrangingPanes = false
    }

    // MARK: - Panes

    /// Creates a pane and its session, force-loading the view so the shell
    /// spawns at the target grid size and directory rather than reflowing.
    /// - Parameter remote: a saved remote side to restore (`#519`). A
    ///   connect-sheet target rebuilds the preset that sheet made, so
    ///   Reconnect runs the same destination; the pane itself shows the
    ///   ended-session panel instead of spawning.
    func makePane(
        workingDirectory: String?, initialGridSize: TerminalSize?, preset: Preset? = nil,
        remote: PaneRemoteRestore? = nil
    ) -> TerminalPaneViewController {
        let pane = TerminalPaneViewController()
        // Before `pane.view` loads: the preset supplies spawn settings.
        if case .target(let key)? = remote, let target = SSHTarget(key: key) {
            pane.preset = SSHDestination.preset(for: target)
        } else {
            pane.preset = preset
        }
        pane.restoredRemote = remote
        // Opens where the focused pane is (OSC 7), else home. The directory is
        // already host-filtered, so a remote path never reaches a local spawn.
        pane.inheritedWorkingDirectory = workingDirectory
        pane.inheritedDirectoryChecked = setup.directoriesChecked
        pane.initialGridSize = initialGridSize
        pane.didSizeWindow = didSetUpWindow
        addChild(pane)
        _ = pane.view
        return pane
    }
}
