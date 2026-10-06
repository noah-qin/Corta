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
import Synchronization

/// Maps a `CortaTerminal.Color` to sRGB RGBA floats: the low 16 from the
/// theme, the 6×6×6 cube and grey ramp from xterm's numbers (never themed:
/// colour 137 means one colour). 24-bit colours bypass this. The drawable
/// is tagged sRGB in `TerminalView`, or P3 screens oversaturate.
nonisolated enum TerminalColorPalette {
    /// The live variant. Written by `apply(_:)` on the main thread; read by
    /// renderers and by `FrameScheduler`'s display-link callback, which are
    /// not. A variant is several words plus an array reference, so an
    /// unsynchronised read could see half of one — TSAN caught a settings
    /// change racing a renderer. The lock is uncontended in practice: a
    /// write per theme change, a read per row.
    private static let storage = Mutex<Theme.Variant>(Theme.corta.dark)

    /// On a theme or appearance change; panes then redraw.
    static func apply(_ variant: Theme.Variant) { storage.withLock { $0 = variant } }

    /// For per-frame callers: one read, then a local, is measurably cheaper
    /// across tens of thousands of cells.
    static var activeVariant: Theme.Variant { storage.withLock { $0 } }

    private static var active: Theme.Variant { activeVariant }

    static var defaultForeground: SIMD4<Float> { active.foreground }
    static var defaultBackground: SIMD4<Float> { active.background }
    static var cursorColor: SIMD4<Float> { active.cursor }

    /// Opaque: the canvas is content, not glass. At 0.72 every colour lost a
    /// fifth of its contrast. The window and the layer are opaque too, so
    /// lowering this alone would only darken the colours.
    static let backgroundOpacity: Float = 1.0

    static var clearColor: SIMD4<Float> {
        let c = defaultBackground
        return SIMD4<Float>(
            c.x * backgroundOpacity, c.y * backgroundOpacity, c.z * backgroundOpacity,
            backgroundOpacity)
    }

    /// Resolves `.default` to the foreground rather than the background.
    static func resolveForeground(_ color: Color) -> SIMD4<Float> {
        active.resolveForeground(color)
    }

    static func resolveBackground(_ color: Color) -> SIMD4<Float> {
        active.resolveBackground(color)
    }
}

/// OSC 4 overrides as a raw dictionary, so the common no-override path
/// stays as cheap as having no override support (`DESIGN.md` §7).
public typealias IndexedColorOverrides = [UInt8: (red: UInt8, green: UInt8, blue: UInt8)]

nonisolated extension Theme.Variant {
    /// On the variant so the render loop can hold it locally; the static path
    /// retains the ANSI array per cell.
    @inline(__always)
    func resolveForeground(
        _ color: Color, indexedOverrides: IndexedColorOverrides = [:]
    ) -> SIMD4<Float> {
        color.isDefault ? foreground : resolve(color, indexedOverrides: indexedOverrides)
    }

    @inline(__always)
    func resolveBackground(
        _ color: Color, indexedOverrides: IndexedColorOverrides = [:]
    ) -> SIMD4<Float> {
        color.isDefault ? background : resolve(color, indexedOverrides: indexedOverrides)
    }

    @inline(__always)
    func resolve(_ color: Color, indexedOverrides: IndexedColorOverrides = [:]) -> SIMD4<Float> {
        if let components = color.components {
            return SIMD4<Float>(
                Float(components.red) / 255, Float(components.green) / 255,
                Float(components.blue) / 255, 1)
        }
        guard let index = color.index else { return foreground }
        if let overridden = indexedOverrides[index] {
            return SIMD4<Float>(
                Float(overridden.red) / 255, Float(overridden.green) / 255,
                Float(overridden.blue) / 255, 1)
        }
        if index < 16 { return ansi[Int(index)] }
        // xterm's cube and ramp, the same under every theme.
        if index < 232 {
            let i = Int(index) - 16
            let levels: [Float] = [0, 95 / 255, 135 / 255, 175 / 255, 215 / 255, 1]
            return SIMD4<Float>(levels[i / 36], levels[(i / 6) % 6], levels[i % 6], 1)
        }
        let level = Float(8 + (Int(index) - 232) * 10) / 255
        return SIMD4<Float>(level, level, level, 1)
    }
}
