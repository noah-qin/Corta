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
import SwiftUI

extension NSToolbarItem.Identifier {
    static let settingsNavigation = Self("corta.settings.navigation")
    static let settingsTitle = Self("corta.settings.title")
}

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    let model = SettingsModel()
    let navigation = SettingsNavigation()
    private var navigationControl: NSSegmentedControl?
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        // No minimize: ⌘, reopens it in an instant, and a settings window
        // has no business in the Dock. Zoom is disabled below for the same
        // reason — the window fits its page (HIG, Settings › macOS).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The sidebar runs up under the titlebar, as System Settings' does.
        // Back, forward and the page's name are toolbar items after the
        // sidebar separator, so they sit above the page like System
        // Settings'; the window's own title stays for Accessibility.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // Found by tests and Accessibility whatever page names the window.
        window.identifier = NSUserInterfaceItemIdentifier("Corta.Settings")
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Corta.Settings")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: SettingsSidebar(navigation: navigation)))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 280
        sidebar.canCollapse = false
        let detail = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: SettingsView(model: model, navigation: navigation)))
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        trackSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .settingsNavigation, .settingsTitle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .settingsNavigation:
            // One segmented control, back and forward in a shared capsule as
            // System Settings has; its own view, so the two halves can be
            // enabled separately.
            let back = L10n.text("settings.toolbar.back")
            let forward = L10n.text("settings.toolbar.forward")
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back) ?? NSImage(),
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward) ?? NSImage(),
                ],
                trackingMode: .momentary, target: self, action: #selector(navigate(_:)))
            control.segmentStyle = .automatic
            control.setToolTip(back, forSegment: 0)
            control.setToolTip(forward, forSegment: 1)
            control.setWidth(28, forSegment: 0)
            control.setWidth(28, forSegment: 1)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = back
            item.paletteLabel = back
            navigationControl = control
            updateNavigationState()
            return item
        case .settingsTitle:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = titleLabel
            item.isBordered = false
            item.label = ""
            return item
        default:
            return nil
        }
    }

    @objc private func navigate(_: Any?) {
        guard let control = navigationControl else { return }
        if control.selectedSegment == 0 { navigation.goBack() } else { navigation.goForward() }
    }

    private func updateNavigationState() {
        guard let control = navigationControl else { return }
        control.setEnabled(navigation.canGoBack, forSegment: 0)
        control.setEnabled(navigation.canGoForward, forSegment: 1)
    }

    /// The window is named after the page, the way System Settings is.
    private func trackSelection() {
        window?.title = navigation.selection.title
        titleLabel.stringValue = navigation.selection.title
        updateNavigationState()
        withObservationTracking {
            _ = navigation.selection
            _ = navigation.canGoBack
            _ = navigation.canGoForward
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackSelection() }
        }
    }

    // MARK: - Showing

    func open(_ page: SettingsView.Category) {
        navigation.go(to: page)
        show(nil)
    }

    func showPrivacySettings(_: Any?) {
        open(.privacy)
    }

    func showThemeEditor(_: Any?) {
        open(.themes)
        navigation.themeEditorRequest += 1
    }

    func showHostDetails(_: Any?) {
        open(.appearance)
        navigation.showHostDetails = true
    }

    @objc func show(_ sender: Any?) {
        model.windowWillShow()
        // Give the reused settings window an explicit native presentation
        // style instead of relying on AppKit's inference for this split view.
        window?.animationBehavior =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }
}
