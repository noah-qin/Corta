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

import Cocoa

/// The window controller behind every terminal window, chiefly for
/// `windowShouldClose`: the red button and ⌘W end at the window's delegate,
/// and this is where the "still running" confirmation lives.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private var splitController: SplitViewController? {
        contentViewController as? SplitViewController
    }

    /// The App Intent identity (`TerminalWindowEntity`), carried through
    /// `WindowState` so it survives a relaunch. Never the title, which the
    /// child writes.
    var windowID: String = UUID().uuidString

    /// The Quick Terminal's window: not saved or listed as an ordinary one.
    var isQuickTerminal = false

    /// A titlebar lock while Secure Keyboard Entry is engaged — the effect is
    /// invisible otherwise. Follows `SecureInput.engaged`, not the setting.
    private var secureInputIndicator: NSTitlebarAccessoryViewController?
    private var secureInputObserver: NSObjectProtocol?

    override func windowDidLoad() {
        super.windowDidLoad()
        installSecureInputIndicator()
    }

    /// Swaps the storyboard's `NSWindow` for a non-activating `NSPanel` with
    /// the same content, before it is shown.
    ///
    /// An inactive app's window never reaches a full-screen Space, whatever
    /// its collection behaviour, and `NSApp.activate()` is refused or drags
    /// the user out of the Space. Measured on macOS 27 over full-screen
    /// TextEdit: `kCGWindowIsOnscreen` stayed false for every `NSWindow`
    /// variant and became true for a `.nonactivatingPanel`.
    ///
    /// Done here because this controller knows what `windowDidLoad` put on the
    /// old window (the lock); `viewWillAppear` then runs against the panel as
    /// usual.
    func adoptNonactivatingPanel() {
        guard let old = window, !(old is NSPanel) else { return }
        let panel = NSPanel(
            contentRect: old.contentRect(forFrameRect: old.frame),
            styleMask: old.styleMask.union(.nonactivatingPanel),
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // `QuickTerminalController` owns dismissal and focus return.
        panel.hidesOnDeactivate = false
        panel.title = old.title
        let content = old.contentViewController
        old.delegate = nil
        old.contentViewController = nil
        panel.contentViewController = content
        panel.delegate = self
        window = panel
        installSecureInputIndicator()
    }

    private func installSecureInputIndicator() {
        guard let window else { return }
        // Once per window owned: drop the previous window's observer.
        if let secureInputObserver { NotificationCenter.default.removeObserver(secureInputObserver) }
        let image = NSImageView(
            image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.toolTip = L10n.text("secureInput.indicator.tooltip")
        image.setAccessibilityLabel(L10n.text("secureInput.indicator.tooltip"))
        image.translatesAutoresizingMaskIntoConstraints = false
        // Sized by frame: AppKit's own accessory constraints conflicted with
        // width/height constraints on every window.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
        container.addSubview(image)
        NSLayoutConstraint.activate([
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        secureInputIndicator = accessory
        secureInputObserver = NotificationCenter.default.addObserver(
            forName: SecureInput.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSecureInputIndicator() }
        }
        updateSecureInputIndicator()
    }

    private func updateSecureInputIndicator() {
        guard let window else { return }
        secureInputIndicator?.isHidden = !(SecureInput.shared.engaged && window.isKeyWindow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let splitController else { return true }
        let running = splitController.panesWithRunningJobs
        return splitController.confirmClose(of: running, scope: L10n.text("close.scope.window"))
    }

    /// Read at quit and on every window close.
    var restorableState: WindowState? {
        guard let window, let splitController, !isQuickTerminal else { return nil }
        var state = splitController.windowState(frame: window.frame)
        state?.id = windowID
        return state
    }
}
