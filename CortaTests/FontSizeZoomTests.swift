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

    @Test func zoomingOneWindowNeverTouchesTheConfigFile() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        let before = ConfigurationStore.shared.configuration
        pane.increaseFontSize(nil)
        pane.increaseFontSize(nil)
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
        paneA.increaseFontSize(nil)
        #expect(paneA.fontSize == originalA + 1)
        #expect(paneB.fontSize == originalB)
        #expect(!paneB.isFontSizeZoomed)
    }

    @Test func resetReturnsToTheLiveConfiguredDefaultNotAConstant() throws {
        let (split, _) = makeSplit()
        defer { split.teardown() }
        let pane = try #require(split.focusedPane)
        pane.increaseFontSize(nil)
        pane.increaseFontSize(nil)
        #expect(pane.isFontSizeZoomed)
        pane.resetFontSize(nil)
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
