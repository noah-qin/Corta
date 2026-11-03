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
    static let cortaNewTab = Self("corta.new-tab")
    static let cortaInputSource = Self("corta.input-source")
    static let cortaTabs = Self("corta.tabs")
}

/// The titlebar row (D30): the tab strip, then the actions. The window
/// controller owns the toolbar; its actions go to the selected tab.
extension TerminalWindowController: NSToolbarDelegate {
    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "Corta.TerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.cortaTabs, .cortaConnect, .cortaNewTab]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.cortaTabs, .flexibleSpace, .space, .cortaConnect, .cortaNewTab, .cortaInputSource]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .cortaTabs:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("tabs.strip")
            item.paletteLabel = item.label
            item.view = tabStrip
            item.isBordered = false
            item.visibilityPriority = .high
            // As wide as the row allows: the strip takes what the actions leave.
            // A range, not a size: the toolbar resizes the item within it.
            tabStrip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
                tabStrip.widthAnchor.constraint(lessThanOrEqualToConstant: 4_000),
                tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),
            ])
            return item
        case .cortaInputSource:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("inputSource.settings.title")
            item.paletteLabel = item.label
            item.view = inputSourceToolbarHost
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        case .cortaNewTab:
            // The tab strip has no "+" of its own; this one is always there.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = TerminalCommand.newTab.title
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(newTabInThisWindow(_:))
            // A bare symbol, not a glass capsule: the band stays quiet.
            item.isBordered = false
            return item
        case .cortaConnect:
            // One button for a terminal and for files: the dialog switches
            // between them, and offers a remote pane's own files first.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("ui.toolbar.connect")
            item.paletteLabel = item.label
            item.toolTip = L10n.text("ui.toolbar.connectHelp")
            item.image = NSImage(systemSymbolName: "network", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(connectRemote(_:))
            item.isBordered = false
            return item
        default:
            return nil
        }
    }

    @objc private func newTabInThisWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(beside: window, sender: sender)
    }

    /// The connect dialog; from a remote pane, with that host's files
    /// offered first — Return opens them, as the old Files button did.
    @objc private func connectRemote(_ sender: Any?) {
        var paneFiles: RemoteConnectPaneFiles?
        if let pane = selectedTab?.split.focusedPane, pane.remote.canBrowseFiles {
            paneFiles = RemoteConnectPaneFiles(
                host: PaneRemote.browseHostName(state: pane.remote.state)
            ) { [weak pane] in pane?.remote.browseRemoteFiles(nil) }
        }
        RemoteConnectController.shared.show(.ssh, sender: sender, paneFiles: paneFiles)
    }
}

extension SplitViewController {
    /// Only the focused pane can publish into this window's single status slot.
    /// Reparent the existing accessible view instead of duplicating input state.
    func placeInputSourceIndicator(from pane: ViewController, configuration: Configuration) {
        let badge = pane.inputSourceIndicator.view
        if focusedPane === pane, tab?.isSelected ?? true, let host = tab?.controller,
           let toolbar = pane.view.window?.toolbar {
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
                if let spacer = host.inputSourceToolbarSpacer,
                   let spacerIndex = toolbar.items.firstIndex(where: { $0 === spacer }) {
                    toolbar.removeItem(at: spacerIndex)
                }
                toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
                host.inputSourceToolbarSpacer = toolbar.items.last
                toolbar.insertItem(withItemIdentifier: .cortaInputSource, at: toolbar.items.count)
            } else if !wanted {
                if let index { toolbar.removeItem(at: index) }
                if let spacer = host.inputSourceToolbarSpacer,
                   let spacerIndex = toolbar.items.firstIndex(where: { $0 === spacer }) {
                    toolbar.removeItem(at: spacerIndex)
                }
                host.inputSourceToolbarSpacer = nil
            }
        }
        if configuration.inputSourceIndicatorPosition == .prompt {
            guard let terminalView = pane.terminalView else { return }
            if badge.superview !== terminalView {
                badge.autoresizingMask = []
                badge.removeFromSuperview()
                terminalView.addSubview(badge)
            }
        } else if focusedPane === pane, tab?.isSelected ?? true,
                  let inputSourceToolbarHost = tab?.controller?.inputSourceToolbarHost,
                  badge.superview !== inputSourceToolbarHost {
            inputSourceToolbarHost.subviews.forEach { $0.removeFromSuperview() }
            badge.removeFromSuperview()
            badge.frame = inputSourceToolbarHost.bounds
            badge.autoresizingMask = [.width, .height]
            inputSourceToolbarHost.addSubview(badge)
        }
    }

}
