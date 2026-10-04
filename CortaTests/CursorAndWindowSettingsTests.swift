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

@MainActor
struct CursorAndWindowSettingsTests {
    @Test func cursorConfigurationRoundTripsAndRejectsMalformedValues() {
        let (config, unknown) = Configuration.parse("cursor-shape = bar\ncursor-blink = true")
        #expect(config.cursorShape == .bar)
        #expect(config.cursorBlink)
        #expect(unknown.isEmpty)
        #expect(Configuration.parse(config.serialized()).configuration == config)
        let (invalid, preserved) = Configuration.parse("cursor-shape = triangle\ncursor-blink = perhaps")
        #expect(invalid.cursorShape == .block)
        #expect(!invalid.cursorBlink)
        #expect(preserved.count == 2)
    }

    @Test func programCursorOverrideAndResetReturnToConfiguredDefault() {
        var terminal = Terminal(rows: 4, columns: 10)
        let pane = ViewController()
        #expect(pane.effectiveCursorStyle(grid: terminal.grid) == .block)
        terminal.feed(Array("\u{1b}[5 q".utf8))
        #expect(terminal.grid.cursorStyleIsExplicit)
        #expect(pane.effectiveCursorStyle(grid: terminal.grid) == .blinkingBar)
        terminal.feed(Array("\u{1b}[?1049h\u{1b}[4 q\u{1b}[?1049l".utf8))
        #expect(pane.effectiveCursorStyle(grid: terminal.grid) == .underline)
        terminal.feed(Array("\u{1b}[0 q".utf8))
        #expect(!terminal.grid.cursorStyleIsExplicit)
        #expect(pane.effectiveCursorStyle(grid: terminal.grid) == .block)
        terminal.feed(Array("\u{1b}[5 q\u{1b}[!p".utf8))
        #expect(!terminal.grid.cursorStyleIsExplicit)
    }

    @Test func smallConfiguredGridsDoNotExpandToRestoreFallbackSize() {
        let visible = NSRect(x: 80, y: 0, width: 1360, height: 875)
        let small = WindowState.Frame(NSRect(x: 100, y: 200, width: 180, height: 120))
        #expect(small.fitting(visibleFrames: [visible], minimumSize: .zero) == small.rect)
        #expect(small.fitting(visibleFrames: [visible]).size == WindowState.Frame.defaultSize)
    }

    @Test func leftDockAndOversizedInitialGridFitUsableScreen() {
        let visible = NSRect(x: 80, y: 0, width: 1360, height: 875)
        let normal = WindowState.Frame(NSRect(x: 0, y: 100, width: 900, height: 560))
            .fitting(visibleFrames: [visible])
        #expect(normal.minX == 80)
        #expect(normal.width == 900)
        let oversized = WindowState.Frame(NSRect(x: 0, y: -500, width: 4000, height: 3000))
            .fitting(visibleFrames: [visible])
        #expect(oversized == visible)
    }

    @Test func restoreUsesOverlappingDisplayAndInitialSizingKeepsPreferredDisplay() {
        let primary = NSRect(x: 80, y: 0, width: 1360, height: 875)
        let secondary = NSRect(x: -1920, y: 40, width: 1920, height: 1040)
        let saved = WindowState.Frame(NSRect(x: -1800, y: 100, width: 900, height: 560))
        #expect(saved.fitting(visibleFrames: [primary, secondary]) == saved.rect)
        let oversized = WindowState.Frame(NSRect(x: -100, y: 0, width: 4000, height: 3000))
        #expect(oversized.fitting(visibleFrames: [primary, secondary], preferredFrame: secondary) == secondary)
        #expect(primary.contains(saved.fitting(visibleFrames: [primary])))
    }
}
