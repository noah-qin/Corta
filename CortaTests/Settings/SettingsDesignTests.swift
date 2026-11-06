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
import Testing

@testable import Corta

@MainActor
struct SettingsDesignTests {
    @Test("settings search finds the page containing a setting, including command titles")
    func searchFindsSettings() {
        let examples: [(SettingsView.Category, String)] = [
            (.general, "settings.label.restoreWindows"), (.appearance, "settings.label.cjkFont"),
            (.themes, "theme.create"), (.terminal, "settings.label.scrollback"),
            (.keyboardMouse, "settings.label.copyOnSelect"),
            (.connections, "ui.presets.environment"), (.privacy, "settings.label.directoryHistoryClear"),
        ]
        for (category, key) in examples {
            #expect(category.matches(L10n.text(key)))
        }
        #expect(SettingsView.Category.shortcuts.matches(TerminalCommand.splitRight.title))
        for category in SettingsView.Category.allCases {
            #expect(category.matches("  "))
            #expect(category.matches(category.title))
            #expect(!category.matches("no-such-setting-9834421"))
        }
    }

    /// Opt-in offscreen rendering exercises the real SwiftUI views and native
    /// controls without opening or interacting with any user window.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORTA_RENDER_SETTINGS"] == "1"))
    func renderSettingsPages() async throws {
        let directory = URL(fileURLWithPath: "/tmp/corta-settings-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for category in SettingsView.Category.allCases {
                try await render(category, dark: dark, width: 940, directory: directory)
            }
        }
        for category in [
            SettingsView.Category.appearance, .themes, .keyboardMouse, .connections,
        ] {
            try await render(category, dark: false, width: 760, directory: directory)
        }
    }

    private func render(_ category: SettingsView.Category, dark: Bool, width: CGFloat, directory: URL) async throws {
        let controller = SettingsWindowController()
        controller.navigation.go(to: category)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: width, height: 640))
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        frame.layoutSubtreeIfNeeded()
        #expect(window.title == category.title)
        let titleItem = try #require(window.toolbar?.items.first { $0.itemIdentifier == .settingsTitle })
        #expect((titleItem.view as? NSTextField)?.stringValue == category.title)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
            to: directory.appendingPathComponent("\(category.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
        window.close()
    }

    @Test("settings navigation preserves history and clears a stale forward destination")
    func navigationHistory() {
        let navigation = SettingsNavigation()
        navigation.goBack()
        navigation.goForward()
        #expect(navigation.selection == .general)
        #expect(!navigation.canGoBack && !navigation.canGoForward)
        navigation.go(to: .general)
        #expect(!navigation.canGoBack)
        navigation.go(to: .appearance)
        navigation.go(to: .themes)
        navigation.goBack()
        #expect(navigation.selection == .appearance && navigation.canGoForward)
        navigation.goForward()
        #expect(navigation.selection == .themes && !navigation.canGoForward)
        navigation.goBack()
        navigation.go(to: .terminal)
        #expect(navigation.selection == .terminal && !navigation.canGoForward)
        navigation.goBack()
        navigation.goBack()
        #expect(navigation.selection == .general && !navigation.canGoBack)
    }
}
