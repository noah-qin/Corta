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

/// A font-size change from ⌘+/⌘−/pinch is a temporary, per-window
/// zoom, not a write to the config file. Written into
/// `Configuration.fontSize`, a zoom in one window would change every other
/// open window's size (and the saved default) the moment either next
/// re-read the config.
///
/// Real panes, like `PaneZoomTests`: each spawns a genuine `zsh -l`, torn
/// down at the end of every test. Never writes `ConfigurationStore.shared`
/// (`docs/DECISIONS.md` D13 — never change the machine to test); every assertion here
/// either reads it or checks it is unchanged.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct FontSizeZoomTests {
    private func makeSplit() -> (SplitViewController, NSWindow) {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        return (split, window)
    }

    /// The usable height left over under the last row: zero when the grid
    /// fills the pane exactly.
    private func remainder(_ pane: ViewController) throws -> CGFloat {
        let cell = try #require(pane.terminalRenderer).pointMetrics.cellHeight
        let usable = pane.view.bounds.height - pane.verticalInsets
        let rows = (usable / cell + 0.001).rounded(.down)
        return usable - rows * cell
    }

    /// A lone pane's window keeps its place: the top edge stays, the size
    /// moves by less than a cell so the new font's grid fills it exactly —
    /// the same gap under the last row at every size — and a run of steps
    /// does not walk the window.
    @Test func changingFontSizeFitsTheWindowToWholeCellsInPlace() throws {
        let (split, window) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        split.viewWillAppear()
        split.viewDidAppear()
        let frame = window.frame
        let oldColumns = pane.gridSize(fitting: pane.view.bounds.size).columns
        pane.commands.increaseFontSize(nil)
        let zoomedCell = try #require(pane.terminalRenderer).pointMetrics
        #expect(window.frame.maxY == frame.maxY)
        #expect(abs(window.frame.height - frame.height) < zoomedCell.cellHeight)
        #expect(abs(window.frame.width - frame.width) < zoomedCell.cellWidth)
        #expect(try remainder(pane) < 0.01)
        #expect(!pane.windowTitle.composed.contains("×"))
        #expect(pane.gridSize(fitting: pane.view.bounds.size).columns < oldColumns)

        pane.commands.resetFontSize(nil)
        let reset = window.frame
        #expect(reset.maxY == frame.maxY)
        #expect(try remainder(pane) < 0.01)
        // The same run again lands on the same frames: rounded from where
        // the run began, not from the step before.
        pane.commands.increaseFontSize(nil)
        pane.commands.increaseFontSize(nil)
        pane.commands.decreaseFontSize(nil)
        pane.commands.resetFontSize(nil)
        #expect(window.frame == reset)

        pane.commands.increaseFontSize(nil)
        split.splitRight(nil)
        #expect(split.panes.allSatisfy { $0.fontSize == pane.fontSize && $0.isFontSizeZoomed })
        // With splits no window size fits every grid: the frame stays.
        let splitFrame = window.frame
        pane.commands.increaseFontSize(nil)
        #expect(window.frame == splitFrame)
        #expect(split.panes.allSatisfy { $0.fontSize == pane.fontSize })
    }

    /// The Quick Terminal's panel is docked to its screen's edge; a zoom
    /// refits its grid and leaves its frame.
    @Test func aPanelKeepsItsFrame() throws {
        let split = SplitViewController()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = split
        _ = split.view
        split.view.layoutSubtreeIfNeeded()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        split.viewWillAppear()
        split.viewDidAppear()
        let frame = panel.frame
        pane.commands.increaseFontSize(nil)
        #expect(panel.frame == frame)
    }

    @Test func zoomingOneWindowNeverTouchesTheConfigFile() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        let before = ConfigurationStore.shared.configuration
        pane.commands.increaseFontSize(nil)
        pane.commands.increaseFontSize(nil)
        #expect(pane.isFontSizeZoomed)
        #expect(ConfigurationStore.shared.configuration == before)
    }

    @Test func zoomingOneWindowDoesNotAffectAnother() throws {
        let (splitA, _) = makeSplit()
        let (splitB, _) = makeSplit()
        defer {
            splitA.teardown()
            splitB.teardown()
        }
        let paneA = try #require(splitA.focusedPane)
        let paneB = try #require(splitB.focusedPane)
        let originalA = paneA.fontSize
        let originalB = paneB.fontSize
        paneA.commands.increaseFontSize(nil)
        #expect(paneA.fontSize == originalA + 1)
        #expect(paneB.fontSize == originalB)
        #expect(!paneB.isFontSizeZoomed)
    }

    @Test func resetReturnsToTheLiveConfiguredDefaultNotAConstant() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.commands.increaseFontSize(nil)
        pane.commands.increaseFontSize(nil)
        #expect(pane.isFontSizeZoomed)
        pane.commands.resetFontSize(nil)
        #expect(!pane.isFontSizeZoomed)
        #expect(pane.fontSize == CGFloat(ConfigurationStore.shared.configuration.fontSize))
    }

    /// `configurationChanged` must not apply `Configuration.fontSize` to a
    /// zoomed pane, or it snaps back to the default the moment *anything*
    /// in the config changes — not only a font-size edit.
    @Test func aZoomedPaneIgnoresAConfigurationChange() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.isFontSizeZoomed = true
        pane.fontSize = 999
        pane.configurationChanged()
        #expect(pane.fontSize == 999)
    }

    /// The other half: an *un*zoomed pane still tracks the config file, so
    /// the fix does not turn every pane into a permanent zoom.
    @Test func anUnzoomedPaneStillTracksTheConfiguration() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.isFontSizeZoomed = false
        pane.fontSize = 999
        pane.configurationChanged()
        #expect(pane.fontSize == CGFloat(ConfigurationStore.shared.configuration.fontSize))
    }
}
