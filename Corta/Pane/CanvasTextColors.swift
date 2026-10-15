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

/// Text drawn straight onto the terminal canvas takes the theme's colours,
/// built-in or from the config file — never a system label colour, which
/// follows macOS appearance rather than the canvas under it: a theme whose
/// darkness differs from the system's drew near-black text on a dark canvas
/// (#346, #348). Read once per frame from the live palette, and part of a
/// presentation key, so a theme change reaches an overlay already showing.
/// Increase Contrast strengthens every tone, as it promotes secondary
/// labels elsewhere.
nonisolated struct CanvasTextColors: Equatable {
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var increaseContrast: Bool

    /// The live palette and the system's contrast setting, now.
    @MainActor static var current: CanvasTextColors {
        let variant = TerminalColorPalette.activeVariant
        return CanvasTextColors(
            foreground: variant.foreground, background: variant.background,
            increaseContrast: SystemAccessibility.increaseContrast)
    }

    /// The foreground at `alpha`, or at `contrastAlpha` under Increase
    /// Contrast.
    func text(alpha: CGFloat, contrastAlpha: CGFloat) -> CGColor {
        Self.srgb(foreground, alpha: increaseContrast ? contrastAlpha : alpha)
    }

    /// The canvas itself, opaque: what an overlay covering output fills with.
    var backdrop: CGColor { Self.srgb(background, alpha: 1) }

    /// Whether the canvas is dark, by its relative luminance — not whether
    /// macOS is.
    var isDark: Bool {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(background.x) + 0.7152 * linear(background.y) + 0.0722 * linear(background.z) <= 0.179
    }

    /// The appearance a system colour drawn on the canvas resolves against:
    /// dark on a dark canvas whatever macOS is, so `systemIndigo` and the
    /// label colours take the variant that reads there.
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    private static func srgb(_ color: SIMD4<Float>, alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: alpha)
    }
}
