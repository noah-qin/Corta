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

/// The command palette: type part of a name, press Return.
///
/// `CommandPaletteModel` filters and selects; `CommandPaletteView` lays
/// out. This builds the AppKit panel and its `NSGlassEffectView`, keeping
/// Reduce Transparency handling identical to the search bar's.
///
/// Commands go through `NSApp.sendAction(_:to:from:)` with a nil target —
/// the responder chain, as a menu item does. The panel closes first, since
/// while it is key the chain would start at the palette.
@MainActor
final class CommandPaletteController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteController()

    let model = CommandPaletteModel()
    /// The window it opened over; the palette is key while up.
    private weak var invokingWindow: NSWindow?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CommandPaletteView.size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = Self.buildContentView(model: model)
        model.onRun = { [weak self] command in
            self?.close()
            // Once the terminal window is key again.
            DispatchQueue.main.async {
                NSApp.sendAction(command.action, to: nil, from: nil)
            }
        }
        model.onDismiss = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presenting

    @objc func show(_ sender: Any?) {
        guard let window else { return }
        invokingWindow = NSApp.keyWindow
        model.reset()
        if let host = invokingWindow {
            // Centred, a third of the way down, clear of the prompt.
            let frame = window.frame
            window.setFrameOrigin(
                NSPoint(
                    x: host.frame.midX - frame.width / 2,
                    y: host.frame.maxY - frame.height - host.frame.height / 6))
        } else {
            window.center()
        }
        showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    override func close() {
        window?.orderOut(nil)
        invokingWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Layout

    /// Glass for floating chrome, like the search bar; one surface, so no
    /// container.
    private static func buildContentView(model: CommandPaletteModel) -> NSView {
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The panel is titled, for key status, with its titlebar hidden under
        // the content; left in, the titlebar's safe area pushed the search
        // field a whole titlebar height down from the top edge.
        hosting.safeAreaRegions = []

        let content = NSGlassEffectView()
        content.style = .regular
        // Reduce Transparency: opaque tint and a drawn border, as the search bar.
        if SystemAccessibility.reduceTransparency {
            content.tintColor = .windowBackgroundColor
        }
        if SystemAccessibility.increaseContrast || SystemAccessibility.reduceTransparency {
            content.wantsLayer = true
            let border = SystemAccessibility.panelBorder
            content.layer?.borderColor = border.color.cgColor
            content.layer?.borderWidth = border.width
        }
        let wrapper = NSView()
        wrapper.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: wrapper.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        content.contentView = wrapper
        // The window-corner radius (as `TerminalView`), not a pill: a panel
        // reads as a window.
        content.cornerRadius = 10
        return content
    }
}
