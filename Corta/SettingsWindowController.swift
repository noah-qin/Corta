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

/// The settings window.
///
/// A thin AppKit shell: a split view whose sidebar item hosts
/// `SettingsSidebar` and whose detail hosts `SettingsView` (SwiftUI), which
/// owns every control; `SettingsModel` owns the state. See those types' doc
/// comments for what and why — this class only creates the window, names it
/// after the selected page and forwards `show(_:)`.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    let model = SettingsModel()
    private let navigation = SettingsNavigation()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The sidebar runs up under the titlebar, as System Settings' does;
        // an empty toolbar is what gives the titlebar its unified height.
        window.toolbar = NSToolbar(identifier: "Corta.Settings")
        window.toolbarStyle = .unified
        // Found by tests and Accessibility whatever page names the window.
        window.identifier = NSUserInterfaceItemIdentifier("Corta.Settings")
        super.init(window: window)

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: SettingsSidebar(navigation: navigation)))
        sidebar.minimumThickness = 210
        sidebar.maximumThickness = 280
        sidebar.canCollapse = false
        let detail = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: SettingsView(model: model, navigation: navigation)))
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 680, height: 440)
        window.center()
        trackSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The window is named after the page, the way System Settings is.
    private func trackSelection() {
        window?.title = navigation.selection.title
        withObservationTracking {
            _ = navigation.selection
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackSelection() }
        }
    }

    func showPrivacySettings(_ sender: Any?) {
        navigation.selection = .privacy
        show(sender)
    }

    func showThemeEditor(_ sender: Any?) {
        navigation.selection = .appearance
        show(sender)
        navigation.themeEditorRequest += 1
    }

    func showHostDetails(_ sender: Any?) {
        navigation.selection = .terminal
        show(sender)
        navigation.showHostDetails = true
    }

    @objc func show(_ sender: Any?) {
        model.windowWillShow()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
