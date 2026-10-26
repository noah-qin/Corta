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

/// Searches command records by directory, project, exit status and host
/// (`CommandRecord.host`, recorded while the pane was remote), with find,
/// fill and run. An AppKit window hosting SwiftUI `CommandHistoryView`,
/// state in `CommandHistoryModel`. One shared window, re-targeted at the
/// opening pane, as `ShortcutsWindowController` does.
@MainActor
final class CommandHistoryController: NSWindowController, NSWindowDelegate {
    static let shared = CommandHistoryController()

    let model = CommandHistoryModel()
    private var refreshTask: Task<Void, Never>?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CommandHistoryView.size),
            // A fixed size: narrowed, the filter row squeezed its toggles to
            // nothing.
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("commandHistory.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSHostingController(rootView: CommandHistoryView(model: model))
        content.sizingOptions = []
        window.contentViewController = content
        window.setContentSize(CommandHistoryView.size)
        model.onDismiss = { [weak self] in
            self?.refreshTask?.cancel()
            self?.window?.close()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) { refreshTask?.cancel() }

    func show(for pane: ViewController) {
        model.pane = pane
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.window?.isVisible == true else { return }
                self.model.refresh()
            }
        }
        let shouldCenter = window?.isVisible == false
        let screen = pane.view.window?.screen ?? window?.screen ?? NSScreen.main
        showWindow(nil)
        if shouldCenter, let window, let screen {
            window.contentView?.layoutSubtreeIfNeeded()
            let visible = screen.visibleFrame
            let target = pane.view.window?.frame ?? visible
            window.setFrameOrigin(NSPoint(
                x: min(max(target.midX - window.frame.width / 2, visible.minX), visible.maxX - window.frame.width),
                y: min(max(target.midY - window.frame.height / 2, visible.minY), visible.maxY - window.frame.height)))
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
