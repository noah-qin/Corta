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
    override func draw(_ dirtyRect: NSRect) {
        guard !(window?.windowController is FloatingPaneController) else { return }
        PaneSurfaceView.gutterColor.setFill()
        dirtyRect.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window {
            let chrome = window.frame.height - window.contentLayoutRect.height
            // Unflipped: the top band is high y. It holds no cells or controls.
            if chrome > 0, convert(point, from: superview).y > bounds.height - chrome {
                return nil
            }
        }
        return super.hitTest(point)
    }
}
