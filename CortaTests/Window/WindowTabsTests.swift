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
import Testing

@testable import Corta

/// A window's own tabs (D30): one window, one split view per tab, one shown.
@MainActor
@Suite(.serialized)
struct WindowTabsTests {
    private func makeWindow() throws -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controller: TerminalWindowController) {
        for tab in controller.tabs { tab.split.teardown() }
        controller.window?.close()
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func nativeTabbingIsOffAndTheStripIsInTheTitlebarRow() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        #expect(window.tabbingMode == .disallowed)
        let items = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(items.first == .cortaTabs, "the strip leads the row, beside the traffic lights")
        #expect(controller.tabStrip.items.count == 1)
        // Tabs keep their width and sit leading; they do not fill the row.
        controller.addTab()
        let strip = controller.tabStrip
        // Laid out directly: in the toolbar, Auto Layout owns the frame.
        strip.frame.size.width = 900
        strip.layout()
        #expect(strip.tabView(at: 0)?.frame.width == TabStripView.tabWidth)
        #expect(strip.tabView(at: 1)?.frame.minX == TabStripView.tabWidth)
        strip.frame.size.width = 300
        strip.layout()
        #expect(strip.tabView(at: 1)?.frame.maxX == 300, "too many to fit: they share the row")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func addingSelectingAndClosingTabs() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab()
        #expect(controller.tabs.map(\.id) == [first, second, third].map(\.id))
        #expect(controller.selectedTab === third, "a new tab comes to the front")
        // The tab that was in front stays drawn over the new one until its
        // shell has drawn output, then goes.
        if controller.window?.isVisible == true, !(third.split.focusedPane?.drewFirstOutput ?? true) {
            #expect(!second.split.view.isHidden, "held over the new tab")
        }
        controller.container.releaseHeld(animated: false)
        #expect(controller.tabs.filter { !$0.split.view.isHidden }.map(\.id) == [third.id])
        #expect(controller.tabStrip.items.count == 3)
        #expect(controller.tabStrip.selectedIndex == 2)

        controller.selectAdjacentTab(offset: 1)
        #expect(controller.selectedTab === first, "next wraps around")
        controller.selectAdjacentTab(offset: -1)
        #expect(controller.selectedTab === third)
        controller.selectTab(number: 1)
        #expect(controller.selectedTab === first)
        controller.selectTab(number: 9)
        #expect(controller.selectedTab === third, "⌘9 is the last tab")

        controller.closeTab(third)
        #expect(controller.tabs.count == 2)
        #expect(controller.selectedTab === second, "closing the selected tab selects its neighbour")
        #expect(third.split.panes.allSatisfy { $0.didTeardown })
        #expect(controller.window?.isVisible == true)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func reorderingKeepsTheSelection() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab(select: false)
        controller.moveTab(from: 2, to: 0)
        #expect(controller.tabs.map(\.id) == [third, first, second].map(\.id))
        #expect(controller.selectedTab === second)
        #expect(controller.tabStrip.selectedIndex == 2)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aBackgroundTabNeverTakesTheKeyboard() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        let front = try #require(controller.selectedTab)
        let back = controller.addTab(select: false)
        #expect(controller.selectedTab === front)
        back.split.splitRight(nil)
        #expect(back.split.panes.count == 2)
        #expect(back.split.focusedPane === back.split.panes.last, "the split still focuses its new pane")
        let responder = window.firstResponder as? NSView
        #expect(back.split.panes.allSatisfy { responder?.isDescendant(of: $0.view) != true },
                "typing stays with the selected tab")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func closingATabsLastPaneClosesOnlyThatTab() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        second.split.closeTabWithoutAsking()
        #expect(controller.tabs.map(\.id) == [first.id])
        #expect(controller.selectedTab === first)
        #expect(controller.window?.isVisible == true)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func eachTabIsSavedWithItsGroupIndexAndSelection() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        first.customTitle = "build"
        let second = controller.addTab()
        controller.selectTab(first)
        let states = controller.restorableStates
        #expect(states.map(\.id) == [first.id, second.id])
        #expect(states.map(\.tabIndex) == [0, 1])
        #expect(states.map(\.isSelectedTab) == [true, false])
        #expect(Set(states.map(\.tabGroupID)).count == 1)
        #expect(states.first?.tabGroupID != nil)
        #expect(states.first?.customTabTitle == "build")

        controller.closeTab(second)
        let alone = controller.restorableStates
        #expect(alone.count == 1)
        #expect(alone.first?.tabGroupID == nil, "a single tab is a plain window")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aRenameShowsInTheStripAndNotFromOutput() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let tab = try #require(controller.selectedTab)
        controller.tabStrip(controller.tabStrip, rename: tab.id, to: "Production")
        #expect(tab.customTitle == "Production")
        #expect(controller.tabStrip.items.first?.name == "Production")
        #expect(controller.window?.title == "Production")
        controller.tabStrip(controller.tabStrip, rename: tab.id, to: nil)
        #expect(tab.customTitle == nil)
    }

    /// ⌘1–⌘8 show that tab, ⌘9 the last; a number past the last does
    /// nothing, and its menu item says so by being disabled.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func numberedTabCommandsSelectByPlace() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab()
        let split = { try #require(controller.selectedTab?.split) }
        NSApp.sendAction(TerminalCommand.selectTab1.action, to: try split(), from: nil)
        #expect(controller.selectedTab === first)
        NSApp.sendAction(TerminalCommand.selectLastTab.action, to: try split(), from: nil)
        #expect(controller.selectedTab === third)
        NSApp.sendAction(TerminalCommand.selectTab2.action, to: try split(), from: nil)
        #expect(controller.selectedTab === second)
        NSApp.sendAction(TerminalCommand.selectTab5.action, to: try split(), from: nil)
        #expect(controller.selectedTab === second, "there is no fifth tab")

        func enabled(_ command: TerminalCommand) throws -> Bool {
            let item = NSMenuItem(title: "", action: command.action, keyEquivalent: "")
            return try split().validateMenuItem(item)
        }
        #expect(try enabled(.selectTab3))
        #expect(try !enabled(.selectTab4))
        #expect(try enabled(.selectLastTab))
        #expect(TerminalCommand.tabSelection.map { $0.defaultShortcut?.key } == (1...9).map { String($0) })
    }

    /// A rename under way when another tab closes: the view is handed a
    /// different tab, and the edit must not land on it.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aRenameEndsWithoutSavingWhenTheTabsShift() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab()
        controller.tabStrip.beginRename(at: 1)
        let view = try #require(controller.tabStrip.tabView(at: 1))
        #expect(editor(in: view) != nil)
        controller.closeTab(first)
        #expect(editor(in: view) == nil, "the edit was the closed neighbour's slot")
        #expect(second.customTitle == nil, "an unchanged name is not a rename")
        #expect(third.customTitle == nil)

        // The last view leaves the strip while it edits: nothing is saved.
        controller.tabStrip.beginRename(at: 1)
        let last = try #require(controller.tabStrip.tabView(at: 1))
        (editor(in: last) as? NSTextField)?.stringValue = "Lost"
        controller.closeTab(third)
        #expect(editor(in: last) == nil)
        #expect(second.customTitle == nil, "the name typed for a closed tab lands nowhere")
    }

    /// A rename left open while another tab is clicked commits to the tab
    /// it began on, rather than being dropped with the switch.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func clickingAnotherTabCommitsAnOpenRename() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        controller.selectTab(first)
        controller.beginTabRename()
        let view = try #require(controller.tabStrip.tabView(at: 0))
        let field = try #require(editor(in: view) as? NSTextField)
        // Uncommitted input-method text counts: a Pinyin user may click
        // away before choosing a candidate.
        let text = try #require(field.currentEditor() as? NSTextView)
        text.setMarkedText("Pending", selectedRange: NSRange(location: 7, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.tabStrip(controller.tabStrip, select: 1)
        #expect(controller.selectedTab === second)
        #expect(editor(in: view) == nil)
        #expect(first.customTitle == "Pending")
    }

    /// Escape ends the edit inside `makeFirstResponder(nil)`; the keyboard
    /// must still come back to the terminal, or ⇧⌘[ and Rename Tab… go nowhere.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func escapingARenameGivesTheKeyboardBackToTheTerminal() async throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        controller.beginTabRename()
        let view = try #require(controller.tabStrip.tabView(at: 0))
        let field = try #require(editor(in: view) as? NSTextField)
        let text = try #require(field.currentEditor() as? NSTextView)
        _ = (view as? NSTextFieldDelegate)?.control?(field, textView: text,
                                                     doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor(in: view) == nil)
        // The hand-back runs after the turn, from the main queue.
        let terminal = controller.selectedTab?.split.focusedPane?.terminalView
        let deadline = SuspendingClock.now + .seconds(3) * testTimeoutScale
        while window.firstResponder !== terminal, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal != nil && window.firstResponder === terminal)
    }

    private func editor(in view: NSView) -> NSView? {
        view.subviews.first { $0.accessibilityIdentifier() == "tab-title-editor" }
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aMenuActsOnItsTabAfterTheTabsMove() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let menu = controller.tabStrip.menu(forTab: 0)
        controller.moveTab(from: 0, to: 1)
        let close = try #require(menu.items.first { $0.title == L10n.text("tabs.close") })
        _ = (close.target as? NSObject)?.perform(close.action)
        #expect(controller.tabs.map(\.id) == [second.id], "closed the tab the menu opened over")
        #expect(first.split.panes.allSatisfy { $0.didTeardown })
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func closeOtherTabsClosesEveryOther() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        controller.addTab()
        let keep = controller.addTab()
        controller.addTab()
        controller.closeOtherTabs(than: keep)
        #expect(controller.tabs.map(\.id) == [keep.id])
        #expect(controller.selectedTab === keep)
    }

}

// MARK: - Overflow, renaming and menus

extension WindowTabsTests {
    /// Too many tabs to fit: each keeps its minimum width, name and close
    /// button, and the row scrolls to the selected one.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func tooManyTabsScrollRatherThanShrink() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.splitRight(nil)
        for _ in 0..<7 { controller.addTab(select: false) }
        let strip = controller.tabStrip
        strip.frame.size.width = 296
        strip.layout()
        let tab = try #require(strip.tabView(at: 0))
        tab.layoutSubtreeIfNeeded()
        let icon = try #require(tab.subviews.first { $0 is NSImageView })
        #expect(tab.frame.width == TabStripView.minimumTabWidth)
        #expect(tab.frame.minX == 0, "the first tab is selected and in view")
        #expect(icon.frame.minX >= 0 && icon.frame.maxX <= tab.bounds.width)
        controller.selectTab(controller.tabs[7])
        strip.layout()
        let last = try #require(strip.tabView(at: 7))
        #expect(last.frame.minX >= 0 && last.frame.maxX <= strip.bounds.width, "scrolled to the selected tab")
    }

    /// ⇧⌘D pressed again while the last split still springs open measured a
    /// sliver and crushed the panes (dividers saved at 0.95); and a split
    /// too small for two panes is refused.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func quickSplitsKeepEveryPaneUsable() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 900), display: true)
        let split = try #require(controller.selectedTab?.split)
        // 900 pt: halves of 450 and 225 fit; a third ⇧⌘D would leave two
        // panes under the minimum, and is refused.
        for _ in 0..<3 { split.splitDown(nil) }
        split.splitTransition.finish()
        split.view.layoutSubtreeIfNeeded()
        #expect(split.panes.count == 3)
        for pane in split.panes {
            #expect(pane.view.frame.height >= pane.minimumContentSize.height - 1,
                    "a pane \(pane.view.frame.height) pt tall")
        }
    }

    /// A layout saved crushed comes back with each pane at least its minimum.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aCrushedSavedLayoutIsRestoredUsable() throws {
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 100, y: 100, width: 900, height: 700)),
            layout: .split(vertical: false, position: 0.97,
                           first: .pane(directory: nil, isFocused: true), second: .pane(directory: nil)))
        let controller = TerminalWindowController(setup: .init(restore: state))
        controller.showWindow(nil)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        #expect(split.panes.count == 2)
        for pane in split.panes {
            #expect(pane.view.frame.height >= pane.minimumContentSize.height - 1,
                    "a pane \(pane.view.frame.height) pt tall")
        }
    }
}

@MainActor struct TabStripAppearanceTests {
    /// The selected pill follows the canvas: a theme switch that kept the
    /// same tabs and selection left it in the old theme's colour, a white
    /// pill on a dark band.
    @Test func theSelectedFillFollowsAThemeSwitch() throws {
        let saved = TerminalColorPalette.activeVariant
        defer { TerminalColorPalette.apply(saved) }
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripView.height))
        let items = (0..<2).map {
            TabStripItem(id: "\($0)", programs: [], name: "zsh", context: "", toolTip: "", status: nil, progress: nil)
        }
        // The pill is the strip's, one view that slides to the selected tab.
        func pillRed() throws -> CGFloat {
            let fill = try #require(strip.selection.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
            return try #require(fill.usingColorSpace(.sRGB)).redComponent
        }
        for (variant, light) in [(Theme.corta.dark, false), (Theme.corta.light, true), (Theme.mono.dark, false)] {
            TerminalColorPalette.apply(variant)
            strip.update(items: items, selectedIndex: 1)
            #expect(try light ? pillRed() > 0.99 : pillRed() < 0.5)
        }
    }
}

extension WindowTabsTests {
    /// ⌘+ in one tab zoomed only that tab, while the window's increments
    /// and the documentation call the zoom the window's.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func fontZoomAppliesToEveryTabAndNewTabsInheritIt() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        controller.container.releaseHeld(animated: false)
        controller.selectTab(first)
        let pane = try #require(first.split.focusedPane)
        let before = pane.fontSize
        pane.commands.increaseFontSize(nil)
        #expect(pane.fontSize == before + 1)
        #expect(second.split.panes.allSatisfy { $0.fontSize == before + 1 && $0.isFontSizeZoomed })
        let third = controller.addTab()
        #expect(third.split.panes.allSatisfy { $0.fontSize == before + 1 && $0.isFontSizeZoomed })
        third.split.focusedPane?.commands.resetFontSize(nil)
        #expect(controller.tabs.allSatisfy { $0.split.panes.allSatisfy { !$0.isFontSizeZoomed } })
    }

    /// A tab behind the selected one wrote its own cell size into the
    /// window's resize increments.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aBackgroundTabLeavesTheWindowIncrementsAlone() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        controller.container.releaseHeld(animated: false)
        controller.selectTab(first)
        let window = try #require(controller.window)
        let increments = window.contentResizeIncrements
        let hidden = try #require(second.split.focusedPane)
        hidden.setFontSize(hidden.fontSize + 6)
        #expect(window.contentResizeIncrements == increments)
    }

    /// Choosing the tab already shown took the keyboard from its search
    /// field back to the terminal.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func selectingTheShownTabKeepsItsSearchFieldFocused() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let tab = try #require(controller.selectedTab)
        let window = try #require(controller.window)
        // Hidden, the old rule took the keyboard whatever held it.
        window.orderOut(nil)
        let pane = try #require(tab.split.focusedPane)
        pane.search.show()
        #expect(pane.search.hasKeyboardFocus)
        controller.selectTab(tab)
        #expect(pane.search.hasKeyboardFocus)
        pane.search.close()
    }
}
