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
import CortaTerminal

/// Focus reporting (`?1004`): `CSI I` / `CSI O`, which Neovim's
/// `autoread` and tmux's `focus-events` rely on. Focused means this pane
/// holds the keyboard and its window is key. Two fixed byte strings, no
/// stream text (`SECURITY.md` §2.1).
extension ViewController {
    private static let focusIn: [UInt8] = [0x1B, 0x5B, 0x49]  // CSI I
    private static let focusOut: [UInt8] = [0x1B, 0x5B, 0x4F]  // CSI O

    var hasUserFocus: Bool {
        isFocusedPane && (view.window?.isKeyWindow ?? false)
    }

    /// Reports only real changes; AppKit's key and responder churn would
    /// otherwise stream reports.
    func reportFocusIfNeeded() {
        let focused = hasUserFocus
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        // A failed pane (no Metal 4, no shell) has no session to report to.
        guard let session, session.isFocusReportingEnabled else { return }
        session.write(focused ? Self.focusIn : Self.focusOut)
    }

    /// Filtered to this pane's window, or every pane reports every window.
    func observeWindowFocus() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowFocusChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowFocusChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        reportFocusIfNeeded()
        // Cmd-Tab drops the ring even though the focused pane doesn't change.
        applyFocusAppearance()
    }
}
