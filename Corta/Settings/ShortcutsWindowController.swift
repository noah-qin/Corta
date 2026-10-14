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

/// Help > Keyboard Shortcuts (⌘/): a visible list, since terminal users
/// learn shortcuts on sight. An AppKit shell hosting `ShortcutsView`.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("shortcuts.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ShortcutsView())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
