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

/// Reopen Closed Pane: the arrangement (position, split, divider,
/// directory), never the process or scrollback — hence not "Undo Close".
///
/// One deep: a second record describes a tree the first reopen already
/// changed, so deeper entries are guesses.
extension SplitViewController {
    struct ClosedPane {
        /// Last OSC 7 directory; nil opens home.
        var directory: String?
        /// Weak: if it closed too, the position is gone.
        weak var sibling: ViewController?
        var orientation: SplitOrientation
        /// Left or top, so it returns to its own side.
        var wasFirst: Bool
        /// The divider fraction to restore.
        var position: Double
    }

    /// Records a pane's place before removal; not for a window's last pane,
    /// which is `SessionRestore`'s.
    func noteClosing(_ pane: ViewController) {
        guard hasMultiplePanes,
            let split = pane.view.superview as? NSSplitView, split.subviews.count == 2,
            let index = split.subviews.firstIndex(of: pane.view)
        else {
            lastClosedPane = nil
            return
        }
        let siblingView = split.subviews[index == 0 ? 1 : 0]
        let axis = split.isVertical ? split.bounds.width : split.bounds.height
        let firstExtent =
            split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
        lastClosedPane = ClosedPane(
            directory: pane.session?.workingDirectory,
            sibling: panes.first { $0.view === siblingView || siblingView.isDescendant(of: $0.view) }
                ?? panes.first { $0 !== pane && $0.view.isDescendant(of: siblingView) },
            orientation: split.isVertical ? .columns : .rows,
            wasFirst: index == 0,
            position: axis > 0 ? Double(firstExtent / axis) : 0.5)
    }

    var canReopenClosedPane: Bool { lastClosedPane?.sibling != nil }

    @objc func reopenClosedPane(_ sender: Any?) {
        guard let record = lastClosedPane, let sibling = record.sibling else {
            // The sibling is gone: beep rather than open somewhere arbitrary.
            NSSound.beep()
            return
        }
        lastClosedPane = nil
        focusedPane = sibling
        splitFocusedPane(orientation: record.orientation, workingDirectory: record.directory)
        guard let reopened = focusedPane, reopened !== sibling else { return }
        // `splitFocusedPane` puts it second at half; restore side and divider.
        if record.wasFirst, let split = reopened.view.superview as? NSSplitView,
            split.subviews.count == 2
        {
            split.addSubview(reopened.view, positioned: .below, relativeTo: split.subviews[0])
        }
        view.layoutSubtreeIfNeeded()
        if let split = reopened.view.superview as? NSSplitView {
            let axis = split.isVertical ? split.bounds.width : split.bounds.height
            if axis > 0 { split.setPosition(axis * CGFloat(record.position), ofDividerAt: 0) }
        }
        view.layoutSubtreeIfNeeded()
        for pane in panes { pane.resizeSessionToFitView() }
        view.window?.makeFirstResponder(reopened.terminalView)
        noteLayoutChanged()
    }
}
