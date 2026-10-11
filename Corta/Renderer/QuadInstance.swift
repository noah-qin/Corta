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

import simd

/// Pixel geometry stays Float: glyph bearings may be negative, and scaled
/// glyphs, block pieces and rules use fractional sizes. Texture coordinates
/// are integer pixels, independent of the physical atlas height.
nonisolated struct QuadInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var rgba: UInt32
    /// Zero is solid; .max uses a per-image UV uniform; other entries
    /// index the small pixel-rectangle table.
    var atlasIndex: UInt32

    init(origin: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float>, atlasIndex: UInt32 = 0) {
        self.origin = origin
        self.size = size
        self.atlasIndex = atlasIndex
        rgba = Self.packColor(color)
    }

    init(origin: SIMD2<Float>, size: SIMD2<Float>, rgba: UInt32, atlasIndex: UInt32 = 0) {
        self.origin = origin; self.size = size; self.rgba = rgba; self.atlasIndex = atlasIndex
    }
    static func packColor(_ color: SIMD4<Float>) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return byte(color.x) | byte(color.y) << 8 | byte(color.z) << 16 | byte(color.w) << 24
    }

    var color: SIMD4<Float> {
        SIMD4(Float(rgba & 255), Float((rgba >> 8) & 255),
              Float((rgba >> 16) & 255), Float(rgba >> 24)) / 255
    }
}

/// Per-draw-call uniforms. Mirrors `QuadUniforms` in `Shaders.metal`.
nonisolated struct QuadUniforms {
    var rectOrigin: SIMD2<Float>
    var rectSize: SIMD2<Float>
    var drawableSize: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var imageUVRect: SIMD4<Float> = .zero
}
