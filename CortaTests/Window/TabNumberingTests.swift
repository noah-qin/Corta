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

/// Tabs that show the same title carry their position number before it
/// (#528); a title no other tab shows looks as it always did.
@MainActor
@Suite(.serialized)
struct TabNumberingTests {
    private static func item(_ id: String, name: String = "zsh", context: String = "~") -> TabStripItem {
        TabStripItem(id: id, programs: [.terminal], name: name, context: context, toolTip: "")
    }

    @Test("only titles another tab shares are numbered, by position")
    func duplicatesAreNumberedByPosition() {
        let items = TabStripItem.numberingDuplicates([
            Self.item("a"), Self.item("b", context: "/tmp"), Self.item("c"), Self.item("d", name: "vim"),
        ])
        #expect(items.map(\.number) == [1, nil, 3, nil])
        // The same name in another place is another title; the same title
        // split differently between name and context is the same one.
        let split = TabStripItem.numberingDuplicates([
            Self.item("a", name: "zsh", context: "~"), Self.item("b", name: "zsh ~", context: ""),
        ])
        #expect(split.map(\.number) == [1, 2])
        let lone = TabStripItem.numberingDuplicates([Self.item("a")])
        #expect(lone.map(\.number) == [nil], "one tab, nothing to tell apart")
    }

    @Test("a title change adds or removes the number on every tab it affects")
    func aTitleChangeRenumbers() {
        var items = [Self.item("a"), Self.item("b"), Self.item("c")]
        #expect(TabStripItem.numberingDuplicates(items).map(\.number) == [1, 2, 3])
        items[1].context = "/tmp"  // a `cd`
        #expect(TabStripItem.numberingDuplicates(items).map(\.number) == [1, nil, 3])
        items[2].name = "vim"  // a program starting
        #expect(TabStripItem.numberingDuplicates(items).map(\.number) == [nil, nil, nil])
    }

    @Test("the accessibility label carries the number for a shared title, nothing more for a unique one")
    func theAccessibilityLabelCarriesTheNumber() {
        let items = TabStripItem.numberingDuplicates([Self.item("a"), Self.item("b"), Self.item("c", name: "vim")])
        #expect(TabItemView.accessibilityTitle(for: items[1]) == L10n.format("tabs.numbered", "zsh ~", 2))
        #expect(TabItemView.accessibilityTitle(for: items[1]).contains("2"))
        #expect(TabItemView.accessibilityTitle(for: items[2]) == "vim ~")
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripView.height))
        strip.update(items: items, selectedIndex: 0)
        #expect(strip.tabView(at: 1)?.accessibilityLabel() == TabItemView.accessibilityTitle(for: items[1]))
        #expect(strip.tabView(at: 2)?.accessibilityLabel() == "vim ~")
    }

    private func makeWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controllers: TerminalWindowController?...) {
        for controller in controllers.compactMap({ $0 }) {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
    }

    /// The number shown is the one the tab's ⌘1–⌘8 selects, after a reorder
    /// and a close, and a custom name counts by the name shown.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theShownNumberIsTheShortcutsTarget() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let tabs = [first] + (0..<3).map { _ in controller.addTab() }
        for tab in tabs { tab.customTitle = "build" }
        tabs[2].customTitle = "deploy"
        controller.refreshTabStrip()
        #expect(controller.tabStrip.items.map(\.number) == [1, 2, nil, 4])

        func checkShortcuts() {
            for item in controller.tabStrip.items {
                guard let number = item.number, number <= 8 else { continue }
                controller.selectTab(number: number)
                #expect(controller.selectedTab?.id == item.id, "⌘\(number) selects the tab showing \(number)")
            }
        }
        checkShortcuts()

        controller.moveTab(from: 3, to: 0)
        controller.refreshTabStrip()
        #expect(controller.tabStrip.items.map(\.number) == [1, 2, 3, nil])
        #expect(controller.tabStrip.items.first?.id == tabs[3].id)
        checkShortcuts()

        controller.closeTab(tabs[0])
        controller.refreshTabStrip()
        #expect(controller.tabStrip.items.map(\.number) == [1, 2, nil])
        checkShortcuts()

        controller.closeTab(tabs[1])
        controller.refreshTabStrip()
        #expect(controller.tabStrip.items.map(\.number) == [nil, nil], "the last two titles differ")
    }

    /// A tab moved to another window leaves its old window's numbers and
    /// takes a number in its new one.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aTabMovedToAnotherWindowRenumbersBoth() throws {
        let source = makeWindow()
        let first = try #require(source.selectedTab)
        let second = source.addTab()
        first.customTitle = "logs"
        second.customTitle = "logs"
        source.refreshTabStrip()
        #expect(source.tabStrip.items.map(\.number) == [1, 2])
        let target = try #require(source.moveToNewWindow(second))
        defer { close(source, target) }
        source.refreshTabStrip()
        target.refreshTabStrip()
        #expect(source.tabStrip.items.map(\.number) == [nil])
        let added = target.addTab()
        added.customTitle = "logs"
        target.refreshTabStrip()
        #expect(target.tabStrip.items.map(\.number) == [1, 2])
    }
}
