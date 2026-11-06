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

    /// `split` leaves this window, or closes. A hold or a fade under way was
    /// this window's: it must not reach the view once another window has it.
    func remove(_ split: SplitViewController) {
        if held === split { held = nil }
        if shown === split { shown = nil }
        cancelFade(split.view)
        contentView?.inert.remove(split.view)
        split.view.layer?.removeAllAnimations()
        split.view.alphaValue = 1
        split.view.removeFromSuperview()
        split.removeFromParent()
    }

    private var contentView: WindowContentView? { viewIfLoaded as? WindowContentView }

    private func setHidden(_ hidden: Bool, _ split: SplitViewController) {
        if hidden {
            cancelFade(split.view)
            contentView?.inert.remove(split.view)
        }
        guard split.view.isHidden != hidden else { return }
        split.view.isHidden = hidden
        // A tab going behind has no window event to say so; its reader's
        // priority follows here. One coming forward gets it from its redraw.
        if hidden { for pane in split.panes { pane.updateReaderPriority() } }
    }

    private weak var shown: SplitViewController?
    private var revealsAfterClose = false
    private var fadeGenerations: [ObjectIdentifier: UUID] = [:]
    /// The tab that stays drawn over a new one until the new one has drawn
    /// its shell's first output.
    private weak var held: SplitViewController?

    /// Shows `split`. With `previous`, that tab stays on top until
    /// `releaseHeld()` or a short timeout, so a new tab never flashes an
    /// empty canvas before its prompt arrives. `split` draws beneath it
    /// meanwhile and already has the keyboard.
    func show(_ split: SplitViewController, holding previous: SplitViewController? = nil) {
        releaseHeld(animated: false)
        shown = split
        let holding = previous.flatMap { $0 !== split && $0.parent === self ? $0 : nil }
        for case let child as SplitViewController in children {
            setHidden(child !== split && child !== holding, child)
        }
        contentView?.inert.remove(split.view)
        split.view.frame = view.bounds
        split.view.layer?.removeAnimation(forKey: "corta.tab.content.enter")
        cancelFade(split.view)
        if revealsAfterClose {
            revealsAfterClose = false
            Self.reveal(split.view)
        }
        guard let holding else { return }
        held = holding
        // Still drawn, but no longer the tab: a click belongs to the one
        // that already has the keyboard.
        contentView?.inert.add(holding.view)
        view.addSubview(split.view, positioned: .below, relativeTo: holding.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdLimit) { [weak self, weak holding] in
            guard let self, let holding, self.held === holding else { return }
            self.releaseHeld()
        }
    }

    /// Long enough for a usual shell start, short enough not to feel slow.
    static let holdLimit: TimeInterval = 0.3

    /// Releases the hold only if `split` is the tab held, so a new tab's
    /// first output cannot lift a later hold over another new tab.
    func releaseHeld(ifHolding split: SplitViewController?) {
        guard let split, held === split else { return }
        releaseHeld()
    }

    /// The held tab fades away, unless it has been shown again since: the
    /// switch is seen, as a short cross-fade rather than an empty frame.
    func releaseHeld(animated: Bool = true) {
        guard let held else { return }
        self.held = nil
        guard held !== shown else {
            contentView?.inert.remove(held.view)
            return
        }
        guard animated, view.window?.isVisible == true else {
            setHidden(true, held)
            contentView?.inert.remove(held.view)
            return
        }
        if let shown { Self.reveal(shown.view) }
        fadeOut(held.view) { [weak self, weak held] in
            // Only while it is still this window's: a tab moved away during
            // the fade is another window's to show or hide.
            guard let self, let held, held.parent === self else { return }
            self.contentView?.inert.remove(held.view)
            self.setHidden(held !== self.shown, held)
        }
    }

    /// A closing tab that was in front: it leaves the container now, but its
    /// last frame stays on top until the tab behind it has drawn, then fades.
    /// Hidden tabs do not draw, so showing one at once flashed an empty canvas.
    func retire(_ split: SplitViewController) {
        let content = split.view
        split.removeFromParent()
        guard view.window?.isVisible == true, content.superview === view else {
            content.removeFromSuperview()
            return
        }
        revealsAfterClose = true
        content.isHidden = false
        view.addSubview(content, positioned: .above, relativeTo: nil)
        contentView?.inert.add(content)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameDelay) {
            self.fadeOut(content) { content.removeFromSuperview() }
        }
    }

    /// About two frames: the newly shown tab's first one is presented.
    static let firstFrameDelay: TimeInterval = 0.034
    static let fadeDuration: TimeInterval = 0.24

    /// Move the whole composited terminal surface, including its Metal text,
    /// without resizing the grid or scaling glyphs. Run after the first-frame
    /// hold, so shell startup cannot consume the visible transition.
    private static func reveal(_ content: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        content.wantsLayer = true
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 18
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = fadeDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.layer?.add(group, forKey: "corta.tab.content.enter")
    }

    private func cancelFade(_ content: NSView) {
        fadeGenerations.removeValue(forKey: ObjectIdentifier(content))
        content.layer?.removeAnimation(forKey: "corta.tab.content.leave")
    }

    private func fadeOut(_ content: NSView, completion: @escaping @MainActor () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            completion()
            return
        }
        content.wantsLayer = true
        guard let layer = content.layer else { completion(); return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = -18
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Self.fadeDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        let id = ObjectIdentifier(content)
        let generation = UUID()
        fadeGenerations[id] = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGenerations[id] == generation else { return }
                self.fadeGenerations.removeValue(forKey: id)
                completion()
                layer.removeAnimation(forKey: "corta.tab.content.leave")
            }
        }
        layer.add(group, forKey: "corta.tab.content.leave")
        CATransaction.commit()
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
