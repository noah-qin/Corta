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

/// The header's buttons as AppKit lays them out: where each one sits, and the
/// tone it draws in. How they look on the canvas is the launched app's to judge.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct PaneHeaderTests {
    private func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) { return found }
        }
        return nil
    }

    /// The zoom button is hidden at rest. Its slot used to sit between the split
    /// buttons and Close, a one-button gap that looked like a missing control
    /// (#529); leading the group, it leaves the visible three evenly spaced, and
    /// showing it on hover moves none of them.
    @Test("in a split, the hidden zoom slot leads the group and the rest sit evenly")
    func zoomSlotLeadsTheGroup() throws {
        let split = SplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        split.splitFocusedPane(orientation: .columns)
        defer { split.teardown() }
        split.view.layoutSubtreeIfNeeded()
        let header = try #require(split.panes.first).paneHeader
        header.place()
        header.layoutSubtreeIfNeeded()
        let frames = try ["pane.zoom", "pane.splitRight", "pane.splitDown", "pane.close"].map { identifier in
            let control = try #require(button(identifier, in: header), "\(identifier)")
            return (control, control.convert(control.bounds, to: header))
        }
        let (zoom, splitRight, splitDown, close) = (frames[0], frames[1], frames[2], frames[3])
        #expect(!zoom.0.isHidden, "a split pane offers zoom")
        #expect(zoom.1.maxX <= splitRight.1.minX, "the zoom slot leads")
        #expect(splitDown.1.minX - splitRight.1.maxX == close.1.minX - splitDown.1.maxX, "evenly spaced")
        if !SystemAccessibility.isVoiceOverOrSwitchControlRunning {
            #expect(zoom.0.alphaValue == 0, "hidden at rest")
        }
        for (control, _) in frames.dropFirst() {
            #expect(control.alphaValue == 1, "drawn in the tint alone, not faded on top of it (#531)")
            let tint: NSColor = SystemAccessibility.increaseContrast ? .labelColor : .secondaryLabelColor
            #expect(control.contentTintColor == tint)
        }
    }
}
