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
import Metal

/// Evicting a page, and growing or replacing the textures while frames may still sample them.
nonisolated extension GlyphAtlas {
    /// Resets one page in place: its allocator rewinds and its caches clear,
    /// so every lookup re-rasterises into rewritten texels.
    func evict(_ page: AtlasPage) {
        freeRectangleIndices.append(contentsOf: page.rectangleIndices.values)
        page.rectangleIndices.removeAll(keepingCapacity: true)
        page.evict(reservedFirstRow: page === asciiPage)
        if page === asciiPage { asciiTable.update(repeating: nil) }
        evictionCount += 1
        generation += 1
        if texturesInUse() {
            // The page's texels are about to be overwritten. The other
            // grayscale page shares the texture, so its texels come along.
            let kind: TextureKind = page === colorPage ? .color : .grayscale
            replaceTexture(kind, copying: true)
        }
    }

    /// Moves one texture to a fresh allocation, retaining the old
    /// texels when `copying`. Only the CPU writes an atlas; the readback
    /// works for both shared and managed storage. The old texture is
    /// left exactly as queued frames recorded it. Failed allocation leaves
    /// the old texture intact and the caller omits the unavailable glyph.
    func ensureHeight(_ kind: TextureKind, required: Int) -> Bool {
        if blockedTextureWrites.contains(kind) {
            if texturesInUse(), !replaceTexture(kind, copying: true) { return false }
            blockedTextureWrites.remove(kind)
        }
        let old = kind == .color ? colorTexture : texture
        if old.height >= required, old.width == atlasPixelSize { return true }
        var height = min(atlasPixelSize, max(128, old.height))
        while height < required { height = min(atlasPixelSize, height * 2) }
        return replaceTexture(kind, copying: true, height: height, width: atlasPixelSize)
    }

    @discardableResult
    func replaceTexture(_ kind: TextureKind, copying: Bool, height: Int? = nil, width: Int? = nil) -> Bool {
        let old = kind == .color ? colorTexture : texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: old.pixelFormat, width: width ?? old.width, height: height ?? old.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = storageMode
        guard let fresh = allocateTexture(descriptor) else {
            // The old texture stays, possibly still in flight: no texel
            // write until a later replacement succeeds (`ensureHeight`).
            blockedTextureWrites.insert(kind)
            return false
        }
        if copying {
            let bytesPerRow = old.width * (old.pixelFormat == .bgra8Unorm ? 4 : 1)
            let region = MTLRegionMake2D(0, 0, old.width, old.height)
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * old.height)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                old.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                fresh.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        switch kind {
        case .grayscale: texture = fresh
        case .color: colorTexture = fresh
        }
        blockedTextureWrites.remove(kind)
        textureReplacementCount += 1
        onTextureRetired(old)
        return true
    }
}
