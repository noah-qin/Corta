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

/// An overlay on the canvas takes its text colour from the theme, so a theme
/// whose darkness differs from macOS appearance still reads (#348).
@MainActor
struct CanvasOverlayColourTests {
    /// A custom theme whose *light* variant is dark, under macOS Light: the
    /// case where the system label colour drew near-black on near-black.
    /// Built from the theme directly, never applied to the process-wide
    /// palette, which renderers in other suites read.
    private func darkLightVariant() throws -> CanvasTextColors {
        let (configuration, unknown) = Configuration.parse(
            """
            theme = night
            theme.night.light.background = #101010
            theme.night.light.foreground = #e8e8e8
            """)
        #expect(unknown.isEmpty)
        let variant = try #require(Theme.named("night", in: configuration)).variant(dark: false)
        return CanvasTextColors(
            foreground: variant.foreground, background: variant.background, increaseContrast: false)
    }

    private func badge(_ kind: InputSourceState.Kind, canvas: CanvasTextColors?) -> InputSourceIndicatorView {
        let view = InputSourceIndicatorView(frame: CGRect(x: 0, y: 0, width: 28, height: 16))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(view)
        let source = InputSourceState(
            identifier: kind == .direct ? "com.apple.keylayout.ABC" : "com.apple.inputmethod.SCIM.ITABC",
            name: kind == .direct ? "ABC" : "Pinyin", badge: kind == .direct ? "A" : "中", kind: kind)
        view.update(source: source, configuration: Configuration(), canvas: canvas)
        return view
    }

    private func textColour(_ view: InputSourceIndicatorView) throws -> NSColor {
        let label = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
        var resolved: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = label.textColor?.usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }

    @Test func aBadgeBesideThePromptTakesTheThemesForeground() throws {
        let text = try textColour(badge(.direct, canvas: darkLightVariant()))
        // #e8e8e8, faded: light on the #101010 canvas, not the system's dark grey.
        #expect(text.redComponent > 0.85 && text.greenComponent > 0.85 && text.blueComponent > 0.85)
        #expect(text.alphaComponent >= 0.6)
    }

    @Test func anIMEBadgeOnADarkCanvasKeepsAnIndigoThatReads() throws {
        let view = badge(.ime, canvas: try darkLightVariant())
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        // Indigo still, the cue that a mode is on, in the dark variant the
        // canvas's appearance resolves.
        let text = try textColour(view)
        #expect(text.blueComponent > text.greenComponent)
    }

    @Test func aBadgeInTheToolbarKeepsTheSystemColour() throws {
        let text = try textColour(badge(.direct, canvas: nil))
        // Window chrome follows macOS: Light's secondary label is dark.
        #expect(text.redComponent < 0.5 && text.greenComponent < 0.5 && text.blueComponent < 0.5)
    }

    @Test func increaseContrastStrengthensCanvasText() {
        let normal = CanvasTextColors(
            foreground: SIMD4(1, 1, 1, 1), background: SIMD4(0, 0, 0, 1), increaseContrast: false)
        var stronger = normal
        stronger.increaseContrast = true
        #expect(normal.text(alpha: 0.35, contrastAlpha: 0.7).alpha == 0.35)
        #expect(stronger.text(alpha: 0.35, contrastAlpha: 0.7).alpha == 0.7)
    }
}
