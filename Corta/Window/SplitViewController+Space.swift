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

/// What the window needs to know about Space's being on screen.
extension SplitViewController {
    /// Panes on screen: the zoomed one, or the tree's leaves. Space's
    /// sessions out of view do not count.
    var visiblePaneCount: Int {
        if space.isActive { return tree?.leafCount ?? 0 }
        return isPaneZoomed ? 1 : (terminalTree?.leafCount ?? 1)
    }

    /// In Space ⌘W ends the focused session; the window closes only from an
    /// empty project, as a document window with nothing open would. False
    /// in the terminal mode, whose own close applies.
    func performSpaceClose(_ sender: Any?) -> Bool {
        guard space.isActive else { return false }
        if let session = space.focusedSession {
            space.endSession(session)
        } else {
            view.window?.performClose(sender)
        }
        return true
    }

    /// A pane's session ended and the user dismissed it: Space's leaves its
    /// project; the terminal mode's last pane closes the window.
    func closeEndedPane(_ pane: ViewController) {
        if space.owns(pane) {
            space.removeSession(pane)
        } else if terminalTree.leafCount > 1 {
            closePane(pane)
        } else {
            view.window?.performClose(nil)
        }
    }
}
