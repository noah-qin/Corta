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

extension NSToolbarItem.Identifier {
    static let cortaConnect = Self("corta.connect")
    static let cortaFiles = Self("corta.files")
}

/// Only SSH and SFTP are added to the native toolbar; no extra backdrop over it.
extension SplitViewController: NSToolbarDelegate {
    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "Corta.TerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .cortaConnect, .cortaFiles]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .cortaConnect, .cortaFiles]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let key: String
        let symbol: String
        let action: Selector
        switch identifier {
        case .cortaConnect: key = "ui.toolbar.connect"; symbol = "network"; action = #selector(connectSSH(_:))
        case .cortaFiles: key = "ui.toolbar.files"; symbol = "folder"; action = #selector(openRemoteFiles(_:))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = L10n.text(key)
        item.paletteLabel = item.label
        item.toolTip = identifier == .cortaFiles ? L10n.text("ui.toolbar.filesHelp") : item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.target = self
        item.action = action
        return item
    }
    @objc private func connectSSH(_ sender: Any?) { SSHConnectionController.shared.show(sender) }
    @objc private func openRemoteFiles(_ sender: Any?) {
        guard let pane = focusedPane else { return }
        if pane.canBrowseRemoteFiles { pane.browseRemoteFiles(sender); return }
        SFTPBrowserController.showConnection()
    }
}
