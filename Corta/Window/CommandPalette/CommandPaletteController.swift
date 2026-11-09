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
/// out and draws its own glass. This builds the transparent AppKit panel it
/// floats in.
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
        // Clear, so only the view's glass shows; its shape casts the shadow.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = Self.buildContentView(model: model)
        model.isCommandAvailable = { [weak self] command in
            Self.isAvailable(command.action, in: self?.invokingWindow ?? NSApp.mainWindow)
        }
        model.onRun = { [weak self] command in
            self?.close()
            // Once the terminal window is key again. Something may have
            // changed since the list was built: refused or unanswered, it
            // beeps, as a disabled menu item's key does.
            DispatchQueue.main.async {
                guard Self.isAvailable(command.action, in: NSApp.keyWindow),
                    NSApp.sendAction(command.action, to: nil, from: nil)
                else {
                    NSSound.beep()
                    return
                }
            }
        }
        model.onAgent = { [weak self] id in
            self?.close()
            AgentDirectory.focus(id)
        }
        model.onMovePane = { [weak self] id in
            self?.close()
            // Once the terminal window is key again.
            DispatchQueue.main.async {
                NSApp.mainWindow?.terminalSplit?.movePane(toTabWithID: id)
            }
        }
        model.onDismiss = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presenting

    @objc func show(_ sender: Any?) {
        guard let window else { return }
        // Asked again while up: the palette is key, and keeps the window it
        // first opened over — taken as its own opener, Esc reopened it.
        if NSApp.keyWindow !== window { invokingWindow = NSApp.keyWindow }
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

    /// Escape or a command: the palette hands the keyboard back to the
    /// window it opened over.
    override func close() {
        // Taken first: ordering out resigns key, which clears it.
        let returnTo = invokingWindow
        window?.orderOut(nil)
        returnTo?.makeKeyAndOrderFront(nil)
        invokingWindow = nil
    }

    /// Something else took the keyboard — a click in another window, another
    /// app. The palette goes, and that window keeps it: handing it back here
    /// put the opening window over the one just clicked.
    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
        invokingWindow = nil
    }

    // MARK: - Availability

    /// Whether `action` sent from `window` reaches something that accepts it:
    /// its target found along the window's own responder chain — not the
    /// palette's, which is key while it is up — then the window's delegate,
    /// the application and its delegate, and that target's menu validation.
    static func isAvailable(_ action: Selector, in window: NSWindow?) -> Bool {
        guard let target = target(for: action, in: window) else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    private static func target(for action: Selector, in window: NSWindow?) -> AnyObject? {
        var responder: NSResponder? = window?.firstResponder ?? window
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = window?.delegate, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
        return nil
    }

    // MARK: - Layout

    private static func buildContentView(model: CommandPaletteModel) -> NSView {
        let hosting = NSHostingView(rootView: CommandPaletteView(model: model))
        // The panel is titled, for key status, with its titlebar hidden under
        // the content; left in, the titlebar's safe area pushed the search
        // field a whole titlebar height down from the top edge.
        hosting.safeAreaRegions = []
        return hosting
    }
}
