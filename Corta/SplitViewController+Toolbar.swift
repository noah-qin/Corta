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
    static let cortaNewTab = Self("corta.new-tab")
    static let cortaInputSource = Self("corta.input-source")
}

/// Native toolbar actions and a stable, window-local input-source status slot.
extension SplitViewController: NSToolbarDelegate {
    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "Corta.TerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        // The Quick Terminal is one panel, never a tab group: there "+" could
        // only open an unrelated window behind it.
        if window is NSPanel,
            let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .cortaNewTab })
        {
            toolbar.removeItem(at: index)
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .cortaConnect, .cortaFiles, .cortaNewTab]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .cortaConnect, .cortaFiles, .cortaNewTab, .cortaInputSource]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .cortaInputSource {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("inputSource.settings.title")
            item.paletteLabel = item.label
            item.view = inputSourceToolbarHost
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        }
        if identifier == .cortaNewTab {
            // Always there: the tab bar's own "+" goes with the bar, which a
            // window of one tab does not show. The menu's command and title,
            // joined to this window's group whichever window is key.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = TerminalCommand.newTab.title
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(newTabInThisWindow(_:))
            return item
        }
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
    /// Only the focused pane can publish into this window's single status slot.
    /// Reparent the existing accessible view instead of duplicating input state.
    func placeInputSourceIndicator(from pane: ViewController, configuration: Configuration) {
        let badge = pane.inputSourceIndicator.view
        if focusedPane === pane, let toolbar = pane.view.window?.toolbar {
            // Reserve a stable slot while a relevant source is enabled, even
            // when command output temporarily hides the badge. Off, prompt
            // placement and Latin-only automatic mode leave no empty slot.
            let wanted = configuration.inputSourceIndicatorPosition == .toolbar
                && configuration.inputSourceIndicator != .off
                && (configuration.inputSourceIndicator == .always || pane.inputSourceIndicator.automaticallyVisible)
            let index = toolbar.items.firstIndex { $0.itemIdentifier == .cortaInputSource }
            if wanted, index == nil {
                // A native fixed space separates the status badge from the
                // action buttons' shared glass background. Track this exact
                // spacer so disabling the badge preserves user-added spaces.
                if let spacer = inputSourceToolbarSpacer,
                   let spacerIndex = toolbar.items.firstIndex(where: { $0 === spacer }) {
                    toolbar.removeItem(at: spacerIndex)
                }
                toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
                inputSourceToolbarSpacer = toolbar.items.last
                toolbar.insertItem(withItemIdentifier: .cortaInputSource, at: toolbar.items.count)
            } else if !wanted {
                if let index { toolbar.removeItem(at: index) }
                if let spacer = inputSourceToolbarSpacer,
                   let spacerIndex = toolbar.items.firstIndex(where: { $0 === spacer }) {
                    toolbar.removeItem(at: spacerIndex)
                }
                inputSourceToolbarSpacer = nil
            }
        }
        if configuration.inputSourceIndicatorPosition == .prompt {
            guard let terminalView = pane.terminalView else { return }
            if badge.superview !== terminalView {
                badge.autoresizingMask = []
                badge.removeFromSuperview()
                terminalView.addSubview(badge)
            }
        } else if focusedPane === pane, badge.superview !== inputSourceToolbarHost {
            inputSourceToolbarHost.subviews.forEach { $0.removeFromSuperview() }
            badge.removeFromSuperview()
            badge.frame = inputSourceToolbarHost.bounds
            badge.autoresizingMask = [.width, .height]
            inputSourceToolbarHost.addSubview(badge)
        }
    }

    @objc private func newTabInThisWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(beside: view.window, sender: sender)
    }

    @objc private func connectSSH(_ sender: Any?) { RemoteConnectController.shared.show(.ssh, sender: sender) }
    /// A remote pane's own browser; from a local pane, the same connect
    /// sheet as SSH, asking which host.
    @objc private func openRemoteFiles(_ sender: Any?) {
        guard let pane = focusedPane else { return }
        if pane.remote.canBrowseFiles { pane.remote.browseRemoteFiles(sender); return }
        RemoteConnectController.shared.show(.sftp, sender: sender)
    }
}
