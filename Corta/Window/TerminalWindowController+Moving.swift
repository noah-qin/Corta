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

/// Tabs between windows (D30, phase 2): a tab moves with its panes still
/// running — the same split view and sessions, re-hosted — never a copy
/// that restarts its shells.
extension TerminalWindowController {
    /// Window ▸ Move Tab to New Window.
    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let selectedTab else { return }
        moveToNewWindow(selectedTab)
    }

    /// Window ▸ Merge All Windows: every other window's tabs join this one,
    /// after its own, window by window; the emptied windows close.
    @objc func mergeAllWindows(_ sender: Any?) {
        merge((NSApp.delegate as? AppDelegate)?.terminalWindowControllers ?? [])
    }

    /// `others`' tabs join this window, after its own, in order; the
    /// emptied windows close. This window's tab stays in front.
    /// A window asking something in a sheet stays as it is: its question is
    /// about the tabs it holds, and closing it would leave the answer nowhere.
    func merge(_ others: [TerminalWindowController]) {
        guard window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let front = selectedTab
        let asking = others.filter { $0 !== self && $0.window?.attachedSheet != nil }
        if !asking.isEmpty { NSSound.beep() }
        for other in others where other !== self && !asking.contains(where: { $0 === other }) {
            for tab in other.releaseAllTabs() { receive(tab) }
            other.window?.close()
        }
        if let front { selectTab(front) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// `tab` in a window of its own, the same size as this one: with its
    /// top-left corner at `topLeft` (a drop), or cascaded from this window.
    @discardableResult
    func moveToNewWindow(_ tab: TerminalTab, topLeft: NSPoint? = nil) -> TerminalWindowController? {
        guard let window, let delegate = NSApp.delegate as? AppDelegate else { return nil }
        let frame = window.frame
        guard release(tab) else { return nil }
        let controller = TerminalWindowController(adopting: tab, frame: frame)
        delegate.track(controller)
        if let topLeft {
            controller.window?.setFrameTopLeftPoint(topLeft)
        } else {
            delegate.cascade(controller)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        tab.split.didBecomeSelectedTab()
        delegate.noteLayoutChanged()
        return controller
    }

    /// A tab dragged here from another window's strip, at `index`. A window
    /// giving up its last tab goes with it.
    func take(_ tab: TerminalTab, from source: TerminalWindowController, at index: Int) {
        guard source !== self else { return }
        guard window?.attachedSheet == nil, source.window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        if source.tabs.count == 1 {
            _ = source.releaseAllTabs()
            source.window?.close()
        } else {
            source.release(tab)
        }
        receive(tab, at: index)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Where a torn-off tab lands: another window's strip under the pointer,
    /// else a window of its own whose strip is under it. A lone tab dropped
    /// on no strip takes its window there instead.
    func drop(_ tab: TerminalTab, atScreenPoint point: NSPoint) {
        guard let window, let delegate = NSApp.delegate as? AppDelegate else { return }
        // Front to back, this Space only. `isVisible` is true of a window on
        // another Space too. Every window counts as cover, Settings as much as
        // a terminal, or a strip under it would catch the tab; the drag's own
        // preview takes no mouse events and does not.
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.isOnActiveSpace && !$0.ignoresMouseEvents }
        for candidate in windows {
            if let target = candidate.windowController as? TerminalWindowController,
                delegate.terminalWindowControllers.contains(target),
                let index = target.tabStrip.insertionIndex(atScreenPoint: point) {
                if target === self { return }
                target.take(tab, from: self, at: index)
                return
            }
            if candidate.frame.contains(point) { break }
        }
        // The strip's top-left sits under the pointer, about where the tab
        // was held.
        let topLeft = NSPoint(x: point.x - 120, y: point.y + 18)
        if tabs.count == 1 {
            window.setFrameTopLeftPoint(topLeft)
            return
        }
        moveToNewWindow(tab, topLeft: topLeft)
    }
}

extension TerminalWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveTabToNewWindow(_:)):
            return tabs.count > 1
        case #selector(mergeAllWindows(_:)):
            return ((NSApp.delegate as? AppDelegate)?.terminalWindowControllers.count ?? 0) > 1
        default:
            return true
        }
    }
}
