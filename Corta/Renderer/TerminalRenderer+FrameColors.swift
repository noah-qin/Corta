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

import CortaTerminal
import simd

/// The palette one frame draws with: the theme, OSC 10/11/12 over it, and
/// the program's selection colours.
nonisolated extension TerminalRenderer {
    /// OSC 10/11/12 over the theme, as the live frame draws them.
    func applyDynamicColors(to palette: inout Theme.Variant) {
        guard let dynamicColors = frameDynamicColors else { return }
        func rgba(_ color: RGB) -> SIMD4<Float> {
            .init(Float(color.red) / 255, Float(color.green) / 255, Float(color.blue) / 255, 1)
        }
        palette.foreground = rgba(dynamicColors.foreground)
        palette.background = rgba(dynamicColors.background)
        palette.cursor = rgba(dynamicColors.cursor)
    }

    /// The theme under OSC 10/11/12 and the program's selection colours.
    /// - Returns: whether every row must rebuild — a colour changed, or the
    ///   underline colour ids were reclaimed.
    func prepareFramePalette(
        grid: Grid, dynamicColors: DynamicColors?, selectionBackground: Color, selectionForeground: Color
    ) -> Bool {
        var rebuild = false
        framePalette = themeVariant ?? TerminalColorPalette.activeVariant
        if frameDynamicColors != dynamicColors || frameSelectionBackground != selectionBackground
            || frameSelectionForeground != selectionForeground {
            rebuild = true
        }
        frameDynamicColors = dynamicColors
        frameSelectionBackground = selectionBackground
        frameSelectionForeground = selectionForeground
        // Reused ids can compare equal to a retained row built before reclamation.
        if frameUnderlineColors.reclamationGeneration != grid.underlineColors.reclamationGeneration {
            rebuild = true
        }
        frameUnderlineColors = grid.underlineColors
        applyDynamicColors(to: &framePalette)
        // After OSC 10/11: the derived selection and marks follow the canvas drawn.
        frameOverlay = framePalette.overlayColors
        if !selectionBackground.isDefault {
            // The program's hue at the theme's translucency: the selection is
            // drawn over rules and box glyphs, and an opaque one hid them.
            var selection = framePalette.resolveBackground(selectionBackground)
            selection.w = frameOverlay.selection.w
            frameOverlay.selection = selection
        }
        return rebuild
    }
}
