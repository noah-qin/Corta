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

/// A program's own title is only its tab's tooltip. A program that retitles
/// many times a second must not lay the strip out each time: that layout and
/// the transaction it commits were most of what a title flood cost.
@MainActor
struct TabStripToolTipTests {
    private static func item(_ id: String, name: String = "zsh", toolTip: String) -> TabStripItem {
        TabStripItem(id: id, programs: [.terminal], name: name, context: "~", toolTip: toolTip,
                     status: nil, progress: nil)
    }

    private static func settledStrip(_ items: [TabStripItem], selected: Int = 0) -> TabStripView {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripView.height))
        strip.update(items: items, selectedIndex: selected)
        strip.layoutSubtreeIfNeeded()
        strip.needsLayout = false
        for index in items.indices { strip.tabView(at: index)?.needsLayout = false }
        return strip
    }

    @Test("only the tooltip differs")
    func differsOnlyInToolTip() {
        let base = Self.item("1", toolTip: "a")
        #expect(Self.item("1", toolTip: "b").differsOnlyInToolTip(from: base))
        #expect(!base.differsOnlyInToolTip(from: base))
        #expect(!Self.item("1", name: "vim", toolTip: "b").differsOnlyInToolTip(from: base))
        #expect(!Self.item("2", toolTip: "b").differsOnlyInToolTip(from: base))
    }

    @Test("a new title reaches the tooltip without a layout")
    func toolTipAloneSkipsLayout() throws {
        let strip = Self.settledStrip([Self.item("1", toolTip: "t 0"), Self.item("2", toolTip: "x")])
        strip.update(items: [Self.item("1", toolTip: "t 1"), Self.item("2", toolTip: "x")], selectedIndex: 0)
        let first = try #require(strip.tabView(at: 0))
        #expect(first.toolTip == "t 1")
        #expect(strip.tabView(at: 1)?.toolTip == "x")
        #expect(!strip.needsLayout)
        #expect(!first.needsLayout)
        #expect(strip.items.map(\.toolTip) == ["t 1", "x"])
    }

    @Test("a name, a selection or a new tab still takes the full pass")
    func otherChangesLayOut() throws {
        let items = [Self.item("1", toolTip: "t 0"), Self.item("2", toolTip: "x")]
        var strip = Self.settledStrip(items)
        strip.update(items: [Self.item("1", name: "vim", toolTip: "t 1"), items[1]], selectedIndex: 0)
        #expect(strip.needsLayout)
        #expect(strip.tabView(at: 0)?.toolTip == "t 1")

        strip = Self.settledStrip(items)
        strip.update(items: [Self.item("1", toolTip: "t 1"), items[1]], selectedIndex: 1)
        #expect(strip.needsLayout)
        #expect(strip.selectedIndex == 1)

        strip = Self.settledStrip(items)
        strip.update(items: items + [Self.item("3", toolTip: "y")], selectedIndex: 0)
        #expect(strip.tabView(at: 2) != nil)
    }
}
