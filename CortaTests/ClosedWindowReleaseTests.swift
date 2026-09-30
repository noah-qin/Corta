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
import Testing

@testable import Corta

/// A closed window keeps its view tree, so `viewDidMoveToWindow` never sees
/// `nil` and never tears the display link down; the link would stay on the
/// main run loop, referencing the pane's layer. `ViewController.teardown`
/// calls `stopRendering`; this pins that it takes the link down while the
/// view is still in its window. What actually kept closed panes alive was a
/// retain cycle through `onKeyBytes` — `PaneTeardownTests` pins that.
@MainActor
@Suite("Closed window release")
struct ClosedWindowReleaseTests {
    @Test func stoppingRenderingTakesTheDisplayLinkDownInsideAWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Joining the window is what creates the link.
        window.contentView = view
        #expect(view.isRendering)

        view.stopRendering()

        #expect(!view.isRendering, "a closed pane's display link would stay on the run loop")
        // Closing leaves the view in the window, which is why teardown has to.
        window.close()
        #expect(view.window === window)
        #expect(!view.isRendering)
    }
}
