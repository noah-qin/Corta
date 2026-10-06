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

/// A terminal window is born at its size (`TerminalWindowController`,
/// `SplitViewController.prepareWindow`), and its child keeps the grid it was
/// spawned with.
///
/// This is what D15's gate used to guard (D.1: a winsize delivered from a
/// transient layout shrank the grid and stranded the prompt). The window now
/// has its final style mask from creation, so the guarantee is a property of
/// the path rather than a gate on it — and is tested as one.
@MainActor
@Suite(.serialized)
struct WindowBirthTests {
    private var configuredGrid: (rows: Int, columns: Int) {
        let configuration = ConfigurationStore.shared.configuration
        return (configuration.rows, configuration.columns)
    }

    /// The child is spawned at the configured grid, the window is sized for
    /// it before it shows, and showing and laying it out sends nothing new.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aNewWindowsChildKeepsTheGridItWasBornAt() throws {
        let controller = TerminalWindowController(setup: .init())
        let window = try #require(controller.window)
        let split = try #require(controller.contentViewController as? SplitViewController)
        defer {
            split.teardown()
            window.close()
        }
        let pane = try #require(split.focusedPane)
        #expect(window.styleMask.contains(.fullSizeContentView), "the mask is final from creation")
        #expect(pane.didSizeWindow, "sized before anything shows it")

        controller.showWindow(nil)
        split.view.layoutSubtreeIfNeeded()

        let sent = try #require(pane.lastRequestedSize)
        #expect(Int(sent.rows) == configuredGrid.rows)
        #expect(Int(sent.columns) == configuredGrid.columns)
        // The window fits that grid, so no later layout has a reason to send
        // another.
        let fitted = pane.gridSize(fitting: pane.view.bounds.size)
        #expect(Int(fitted.rows) == configuredGrid.rows)
        #expect(Int(fitted.columns) == configuredGrid.columns)
    }

    /// Before the window is sized, a layout at any other size reaches the
    /// view but not the child: `didSizeWindow` is the one gate.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aLayoutBeforeSizingNeverReachesTheChild() throws {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: TerminalWindowController.styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        defer {
            split.teardown()
            window.close()
        }
        split.view.layoutSubtreeIfNeeded()
        let pane = try #require(split.focusedPane)
        #expect(!pane.didSizeWindow)
        pane.resizeSessionToFitView(coalesce: false)
        let sent = try #require(pane.lastRequestedSize)
        #expect(Int(sent.rows) == configuredGrid.rows, "a 400×200 layout must not shrink the grid")
        #expect(Int(sent.columns) == configuredGrid.columns)

        split.prepareWindow(window)
        #expect(pane.didSizeWindow)
        let fitted = pane.gridSize(fitting: pane.view.bounds.size)
        #expect(Int(fitted.rows) == configuredGrid.rows)
        #expect(Int(fitted.columns) == configuredGrid.columns)
    }
}
