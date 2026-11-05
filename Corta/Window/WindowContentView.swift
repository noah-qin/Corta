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

/// The window's content view. With `.fullSizeContentView` the content
/// covers the titlebar band and wins hit-testing there; passing the
/// chrome band back to the frame restores titlebar drag and double-click.
final class WindowContentView: NSView {
    /// Subviews still drawn but no longer the tab (`TabContainerViewController`):
    /// a tab held over a new one, a closed one fading. A click passes through
    /// them, or it would focus a pane about to be hidden.
    let inert = NSHashTable<NSView>.weakObjects()

    override func draw(_ dirtyRect: NSRect) {
        PaneSurfaceView.gutterColor.setFill()
        dirtyRect.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window {
            // Pane cards reach `titlebarOverlap` into the band; that part
            // is theirs.
            let chrome = window.frame.height - window.contentLayoutRect.height
                - (window.windowController is TerminalWindowController ? TerminalLayout.titlebarOverlap : 0)
            // Unflipped: the top band is high y. It holds no cells or controls.
            if chrome > 0, convert(point, from: superview).y > bounds.height - chrome {
                return nil
            }
        }
        guard inert.count > 0 else { return super.hitTest(point) }
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for child in subviews.reversed() where !inert.contains(child) {
            if let hit = child.hitTest(local) { return hit }
        }
        return self
    }
}
