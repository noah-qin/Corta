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

/// Space's toolbar items: one button that switches modes, and the sidebar's.
/// Symbols with tooltips, as a toolbar's items are, and each with a menu
/// command (View ▸ Show Space, View ▸ Show Sidebar).
extension CortaSpaceController {
    /// The mode button names what it does now.
    func configureModeItem(_ item: NSToolbarItem) {
        let target = isActive ? "space.command.showTerminal" : "space.command.showSpace"
        item.label = L10n.text(target)
        item.paletteLabel = L10n.text("space.mode")
        item.toolTip = item.label
        item.image = NSImage(
            systemSymbolName: isActive ? "terminal" : "square.grid.2x2", accessibilityDescription: item.label)
    }

    func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .cortaSpace:
            // One button: it shows where it goes — the grid from the terminal,
            // the terminal from Space (`updateToolbarForMode`).
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.action = #selector(SplitViewController.toggleSpaceMode(_:))
            item.visibilityPriority = .high
            configureModeItem(item)
            return item
        case .cortaSpaceSidebar:
            // AppKit's own Toggle Sidebar item places itself only beside a
            // sidebar-behaviour split item; this one goes through the window.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("menu.toggleSidebar")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.action = #selector(SplitViewController.toggleSpaceSidebar(_:))
            item.isNavigational = true
            return item
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier {
    static let cortaSpace = Self("corta.space")
    static let cortaSpaceSidebar = Self("corta.space.sidebar")
}
