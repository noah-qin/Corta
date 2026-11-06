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

/// OSC 4/104's palette: sparse `overrides` over themed `defaults` — ANSI
/// 0–15 from the theme, 16–255 xterm's fixed cube and ramp, since colour 137
/// means one colour under every theme. OSC 5 is `SpecialColors`.
public struct IndexedPalette: Sendable, Equatable {
    // Private setter: `color(at:)` indexes with any `UInt8`, so a shrunk array
    // would trap on the next query.
    public private(set) var defaults: [RGB]
    public internal(set) var overrides: [UInt8: RGB] = [:]

    /// An override changes what an index resolves to, not any `Cell`, so cell
    /// revisions never see it; the renderer compares this instead. A theme
    /// reseed invalidates on its own path.
    public private(set) var overridesGeneration: UInt64 = 0

    public init(defaults: [RGB] = IndexedPalette.xtermDefaults()) {
        precondition(defaults.count == 256, "IndexedPalette.defaults must name all 256 indices")
        self.defaults = defaults
    }

    public func color(at index: UInt8) -> RGB {
        overrides[index] ?? defaults[Int(index)]
    }

    mutating func setOverride(_ index: UInt8, to color: RGB) {
        overrides[index] = color
        overridesGeneration &+= 1
    }

    /// For a live theme switch: a program's overrides survive. RIS assigns a
    /// whole new palette instead.
    public mutating func updateDefaults(
        to newDefaults: [RGB]
    ) {
        precondition(newDefaults.count == 256, "IndexedPalette.defaults must name all 256 indices")
        defaults = newDefaults
    }

    mutating func resetAllOverrides() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        overridesGeneration &+= 1
    }

    mutating func resetOverride(_ index: UInt8) {
        guard overrides[index] != nil else { return }
        overrides[index] = nil
        overridesGeneration &+= 1
    }

    /// 0–15 are placeholders the app replaces with the theme's colours. Public
    /// for the app target's `Theme.Variant.indexedPaletteDefaults`.
    public static func xtermDefaults() -> [RGB] {
        var values = Array(repeating: RGB(red: 0, green: 0, blue: 0), count: 256)
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 {
            values[16 + i] = RGB(red: levels[i / 36], green: levels[(i / 6) % 6], blue: levels[i % 6])
        }
        for i in 0..<24 {
            let level = UInt8(8 + i * 10)
            values[232 + i] = RGB(red: level, green: level, blue: level)
        }
        return values
    }

    public static func == (lhs: IndexedPalette, rhs: IndexedPalette) -> Bool {
        guard lhs.defaults.count == rhs.defaults.count else { return false }
        for i in 0..<lhs.defaults.count where lhs.defaults[i] != rhs.defaults[i] {
            return false
        }
        guard lhs.overrides.count == rhs.overrides.count else { return false }
        for (index, color) in lhs.overrides {
            guard let other = rhs.overrides[index], other == color else { return false }
        }
        return true
    }
}
