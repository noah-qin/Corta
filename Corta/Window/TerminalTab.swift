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

/// One tab of a terminal window (D30): its split view and the panes in it,
/// the identity an App Intent names and restore keeps, and the title the
/// user gave it. Its window controller owns it and shows one tab at a time.
@MainActor
final class TerminalTab {
    let split: SplitViewController
    /// Survives a relaunch (`WindowState.id`); never derived from a title.
    var id = UUID().uuidString
    weak var controller: TerminalWindowController?

    /// User-owned; terminal output never overwrites it. Part of the saved
    /// arrangement, so a rename is written like a move.
    var customTitle: String? {
        didSet {
            guard customTitle != oldValue else { return }
            (NSApp.delegate as? AppDelegate)?.noteLayoutChanged()
            controller?.refreshTabStrip()
        }
    }

    /// The most urgent agent status among the tab's panes, and the first
    /// progress report, for the strip (`AgentDirectory.refreshTabs`).
    var agentStatus: ProgramStatus?
    var agentProgress: ProgramProgress?

    init(split: SplitViewController) {
        self.split = split
        split.tab = self
    }

    var isSelected: Bool { controller?.selectedTab === self }
    var window: NSWindow? { controller?.window }
}

/// The window's content: every tab's split view, stacked, one shown. The
/// others stay in the window, hidden, so their panes keep a window — for
/// titles, notifications and first responder — and their sessions run on.
final class TabContainerViewController: NSViewController {
    override func loadView() {
        view = WindowContentView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
    }

    func add(_ split: SplitViewController, hidden: Bool) {
        addChild(split)
        let content = split.view
        content.isHidden = hidden
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
    }

    func remove(_ split: SplitViewController) {
        split.view.removeFromSuperview()
        split.removeFromParent()
    }

    private weak var shown: SplitViewController?
    /// The tab that stays drawn over a new one until the new one has drawn
    /// its shell's first output.
    private weak var held: SplitViewController?

    /// Shows `split`. With `previous`, that tab stays on top until
    /// `releaseHeld()` or a short timeout, so a new tab never flashes an
    /// empty canvas before its prompt arrives. `split` draws beneath it
    /// meanwhile and already has the keyboard.
    func show(_ split: SplitViewController, holding previous: SplitViewController? = nil) {
        releaseHeld()
        shown = split
        let holding = previous.flatMap { $0 !== split && $0.parent === self ? $0 : nil }
        for case let child as SplitViewController in children {
            child.view.isHidden = child !== split && child !== holding
        }
        split.view.frame = view.bounds
        guard let holding else { return }
        held = holding
        view.addSubview(split.view, positioned: .below, relativeTo: holding.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdLimit) { [weak self, weak holding] in
            guard let self, let holding, self.held === holding else { return }
            self.releaseHeld()
        }
    }

    /// Long enough for a usual shell start, short enough not to feel slow.
    static let holdLimit: TimeInterval = 0.3

    /// The held tab goes, unless it has been shown again since.
    func releaseHeld() {
        guard let held else { return }
        self.held = nil
        held.view.isHidden = held !== shown
    }
}

extension NSWindow {
    /// The split view a window shows: its selected tab's, or the content of
    /// a window that is not a tabbed one (tests host splits that way).
    var terminalSplit: SplitViewController? {
        if let controller = windowController as? TerminalWindowController {
            return controller.selectedTab?.split
        }
        return contentViewController as? SplitViewController
    }

    /// Every tab's split view in this window, in tab order.
    var terminalSplits: [SplitViewController] {
        if let controller = windowController as? TerminalWindowController {
            return controller.tabs.map(\.split)
        }
        return (contentViewController as? SplitViewController).map { [$0] } ?? []
    }
}
