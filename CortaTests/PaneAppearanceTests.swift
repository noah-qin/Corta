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
import CortaTerminal
import Testing

@testable import Corta

/// An appearance change — Dark Mode, a theme, or an accessibility display
/// option such as Increase Contrast — re-applies what a pane baked into
/// layers when it last drew them.
@MainActor
struct PaneAppearanceTests {
    /// Main-actor like the pane it stands in for: its `NSView` is made there,
    /// and Xcode 26 rejects a default initializer that mixes isolations.
    @MainActor private final class Host: PaneAppearanceHost {
        let view = NSView()
        init() {}
        var session: TerminalSession!
        var terminalView: TerminalView!
        var terminalRenderer: TerminalRenderer!
        var splitController: SplitViewController? { nil }
        var didSizeWindow: Bool { true }
        var fontSize: CGFloat = 13
        var fontFamily = Configuration.systemFontFamily
        var isFontSizeZoomed: Bool { false }
        var focusRefreshes = 0
        func resizeSessionToFitView(coalesce: Bool) {}
        func invalidateDisplay() {}
        func refreshFocusAppearance() { focusRefreshes += 1 }
    }

    @Test func anAppearanceChangeRefreshesTheFocusRing() {
        let host = Host()
        let appearance = PaneAppearance(host: host)
        appearance.appearanceChanged()
        #expect(host.focusRefreshes == 1)
    }
}
