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
}

/// Native toolbar actions and a stable, window-local input-source status slot.
extension SplitViewController: NSToolbarDelegate {
    func installToolbar(on window: NSWindow) {
        toolbarWindow = window
        let toolbar = NSToolbar(identifier: "Corta.TerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        // The Quick Terminal is one panel, never a tab group: there "+" could
        // only open an unrelated window behind it, and it has no Space.
        if window is NSPanel {
            for identifier in [NSToolbarItem.Identifier.cortaNewTab, .cortaSpace, .cortaSpaceSidebar] {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
                    toolbar.removeItem(at: index)
                }
            }
        }
        updateToolbarForMode()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A fixed space keeps the mode button its own glass, apart from the
        // connect and new-session group.
        [.cortaSpaceSidebar, .flexibleSpace, .cortaSpace, .space, .cortaConnect, .cortaNewTab]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .cortaSpaceSidebar, .cortaSpace, .cortaConnect, .cortaNewTab, .cortaInputSource]
    }

    /// The sidebar's items show only with Space's sidebar; "+" and the
    /// connect button act on the mode on screen — a tab in the terminal
    /// mode, a session of the project in Space — and say so.
    func updateToolbarForMode() {
        guard let toolbar = toolbarWindow?.toolbar else { return }
        let inSpace = space.isActive
        for item in toolbar.items {
            switch item.itemIdentifier {
            case .cortaSpaceSidebar:
                item.isHidden = !inSpace
            case .cortaSpace:
                space.configureModeItem(item)
            case .cortaNewTab:
                item.label = inSpace ? L10n.text("space.newSession") : TerminalCommand.newTab.title
                item.paletteLabel = item.label
                item.toolTip = item.label
            case .cortaConnect:
                item.toolTip = L10n.text(inSpace ? "space.connectSSH" : "ui.toolbar.connectHelp")
            default:
                break
            }
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = space.toolbarItem(identifier) { return item }
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
            // The only "+": the tab bar has none (`AppDelegate` does not
            // implement `newWindowForTab(_:)`), and this one stays whether or
            // not the bar shows. The menu's command and title, joined to this
            // window's group whichever window is key.
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
        // One button for a terminal and for files: the dialog switches
        // between them, and offers a remote pane's own files first.
        case .cortaConnect: key = "ui.toolbar.connect"; symbol = "network"; action = #selector(connectRemote(_:))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = L10n.text(key)
        item.paletteLabel = item.label
        item.toolTip = L10n.text("ui.toolbar.connectHelp")
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

    /// View ▸ Show Space / Show Terminal: the toolbar's mode switch.
    @objc func toggleSpaceMode(_: Any?) {
        space.setActive(!space.isActive)
    }

    /// View ▸ Jump to Next Waiting Session. Does nothing unless Space is showing.
    @objc func jumpToNextWaitingSession(_: Any?) {
        space.jumpToNextWaiting()
    }

    /// Command palette: send the focused pane's selection to the other member, or ask which.
    @objc func sendSelectionToMember(_: Any?) {
        space.sendSelectionFromPalette()
    }

    /// View ▸ Show/Hide Sidebar and the toolbar's sidebar button. The window
    /// answers it, being always in the responder chain, and hands it to
    /// Space's split.
    @objc func toggleSpaceSidebar(_: Any?) {
        guard space.isActive else { return }
        space.splitController.toggleSidebar(nil)
    }

    /// View ▸ Arrange in Columns: each column of the grid its own heights.
    @objc func arrangeSpaceInColumns(_: Any?) { space.arrange(inColumns: true) }

    /// View ▸ Arrange in Rows: each row of the grid its own widths.
    @objc func arrangeSpaceInRows(_: Any?) { space.arrange(inColumns: false) }

    /// File ▸ Open Project…: a folder for Space, which shows if it was not.
    @objc func openSpaceProject(_: Any?) {
        space.chooseProject()
    }

    @objc private func newTabInThisWindow(_ sender: Any?) {
        if space.isActive {
            space.newSession()
            return
        }
        guard let window = toolbarWindow else { return }
        (NSApp.delegate as? AppDelegate)?.newTab(beside: window, sender: sender)
    }

    /// The connect dialog; from a remote pane, with that host's files
    /// offered first — Return opens them, as the old Files button did.
    @objc private func connectRemote(_ sender: Any?) {
        if space.isActive {
            space.connectSession()
            return
        }
        var paneFiles: RemoteConnectPaneFiles?
        if let pane = focusedPane, pane.remote.canBrowseFiles {
            paneFiles = RemoteConnectPaneFiles(
                host: PaneRemote.browseHostName(state: pane.remote.state)
            ) { [weak pane] in pane?.remote.browseRemoteFiles(nil) }
        }
        RemoteConnectController.shared.show(.ssh, sender: sender, paneFiles: paneFiles)
    }
}
