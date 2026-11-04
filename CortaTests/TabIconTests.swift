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

@MainActor
@Suite(.serialized)
struct TabIconTests {
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func iconTracksSplitsEvenWhenZoomedAndAfterReopening() throws {
        let controller = TerminalWindowController(setup: .init())
        let window = try #require(controller.window)
        let split = try #require(controller.selectedTab?.split)
        defer {
            split.teardown()
            window.close()
        }
        controller.showWindow(nil)
        controller.refreshTabTitle()
        #expect(try iconWidth(in: window) == 32)

        // Each pane behind the focused one fans out 8 points further.
        split.splitFocusedPane(orientation: .columns)
        #expect(split.panes.count == 2)
        #expect(try iconWidth(in: window) == 40)
        split.zoomFocusedPane()
        controller.refreshTabTitle()
        #expect(try iconWidth(in: window) == 40, "zoom does not remove the other sessions")
        split.unzoomPane()

        split.splitFocusedPane(orientation: .rows)
        #expect(try iconWidth(in: window) == 48)
        split.closePane(try #require(split.focusedPane))
        #expect(try iconWidth(in: window) == 40)
        split.closePane(try #require(split.focusedPane))
        #expect(split.panes.count == 1)
        #expect(try iconWidth(in: window) == 32)
        split.reopenClosedPane(nil)
        #expect(split.panes.count == 2)
        #expect(try iconWidth(in: window) == 40)
    }

    /// The width of the icon stack the strip shows for the selected tab.
    private func iconWidth(in window: NSWindow) throws -> CGFloat {
        let controller = try #require(window.windowController as? TerminalWindowController)
        let tab = try #require(controller.selectedTab)
        let item = TabIcon.item(for: tab)
        #expect(controller.tabStrip.items.first?.programs == item.programs)
        return try #require(TabIcon.image(for: item.programs)).size.width
    }
}
