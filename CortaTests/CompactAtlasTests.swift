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
import Darwin
import Foundation
import CoreText
import Metal
import Testing
@testable import Corta

@Suite(.serialized, .metalSerialized) struct CompactAtlasTests {
    @Test func instanceABIAndGeometry() {
        #expect(MemoryLayout<QuadInstance>.stride == 24)
        #expect(MemoryLayout<QuadInstance>.alignment == 8)
        #expect(MemoryLayout<QuadUniforms>.stride == 48)
        #expect(MemoryLayout<QuadUniforms>.offset(of: \.imageUVRect) == 32)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.origin) == 0)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.size) == 8)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.rgba) == 16)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.atlasIndex) == 20)
        let q = QuadInstance(origin: .init(-2.5, -1.25), size: .init(13.125, 27.75), color: .init(0.2, 0.4, 0.6, 0.5))
        #expect(q.origin == .init(-2.5, -1.25))
        #expect(q.size == .init(13.125, 27.75))
        #expect(q.rgba == 0x80996633)
    }
    @Test func lazyColorAndGrowthRetireOldTextures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
        let atlas = try GlyphAtlas(device: device, font: font)
        #expect(atlas.texture.height == 128)
        #expect(atlas.colorTexture.width == 1)
        #expect(atlas.texture.storageMode == .shared)
        let old = atlas.texture
        let generation = atlas.generation
        var retired: [MTLTexture] = []
        atlas.onTextureRetired = { retired.append($0) }
        atlas.texturesInUse = { true }
        let first = try #require(atlas.glyph(forASCII: 0x41, style: .regular))
        let rect = atlas.atlasRects[Int(first.atlasIndex) - 1]
        for style in [GlyphAtlas.Style.regular, .bold, .italic, .boldItalic] {
            for scalar in UInt32(0x20)...UInt32(0x7E) { _ = atlas.glyph(forASCII: scalar, style: style) }
        }
        for scalar in UInt32(0x4E00)...UInt32(0x4E20) { _ = atlas.glyph(shaping: scalar, style: .regular) }
        #expect(atlas.texture.height > 128)
        #expect(atlas.generation == generation)
        #expect(atlas.atlasRects[Int(first.atlasIndex) - 1] == rect)
        #expect(retired.contains { $0 === old })
        _ = atlas.glyph(shaping: 0x1F680, style: .regular)
        #expect(atlas.colorTexture.width > 1)
        atlas.reset(font: font)
        #expect(atlas.texture.height == 128)
        #expect(atlas.colorTexture.width == 1)
    }
    @Test func failedGrowthNeverPublishesOutOfBoundsGlyph() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
        let atlas = try GlyphAtlas(device: device, font: font) { descriptor in
            descriptor.height > 128 ? nil : device.makeTexture(descriptor: descriptor)
        }
        for scalar in UInt32(0x4E00)...UInt32(0x4E40) {
            if let glyph = atlas.glyph(shaping: scalar, style: .regular), glyph.atlasIndex > 0 {
                let rect = atlas.atlasRects[Int(glyph.atlasIndex) - 1]
                #expect(Int(rect.y) + Int(rect.w) <= atlas.texture.height)
            }
        }
    }
    @Test func failedResetDoesNotOverwriteInFlightTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
        var allow = true
        let atlas = try GlyphAtlas(device: device, font: font) { descriptor in
            allow ? device.makeTexture(descriptor: descriptor) : nil
        }
        _ = atlas.glyph(forASCII: 0x41, style: .regular)
        let old = atlas.texture
        func bytes() -> [UInt8] {
            var result = [UInt8](repeating: 0, count: old.width * old.height)
            old.getBytes(&result, bytesPerRow: old.width,
                from: MTLRegionMake2D(0, 0, old.width, old.height), mipmapLevel: 0)
            return result
        }
        let before = bytes()
        allow = false
        atlas.texturesInUse = { true }
        atlas.reset(font: font)
        _ = atlas.glyph(forASCII: 0x42, style: .regular)
        #expect(bytes() == before)
        atlas.texturesInUse = { false }
        let glyph = try #require(atlas.glyph(forASCII: 0x43, style: .regular))
        #expect(glyph.atlasIndex > 0)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func fractionalImageCropPreservesUVs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 10, height: 10, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 0, count: 400)
        for y in 0..<10 { for x in 0..<10 {
            pixels[(y * 10 + x) * 4 + 2] = UInt8(y * 25)
            pixels[(y * 10 + x) * 4 + 3] = 255
        } }
        texture.replace(region: MTLRegionMake2D(0, 0, 10, 10), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 40)
        let backend = try Metal4Backend(device: device)
        let target = MetalRenderTarget.make(device: device, width: 32, height: 32)
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        #expect(backend.renderFrameAndWait(into: target) { backend in
            backend.drawColorQuads([QuadInstance(origin: .zero, size: .init(32, 32),
                color: .one, atlasIndex: .max)], atlas: texture, rect: rect,
                drawableSize: rect.size, imageUVRect: .init(0, 1.0 / 3, 1, 2.0 / 3))
        })
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(16, 0, 1, 1), mipmapLevel: 0)
        #expect(abs(Int(pixel[2]) - 73) <= 1)
    }

    @Test func kittyStorageModeMeasurement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Data(repeating: 255, count: 128 * 128 * 4).base64EncodedString()
        terminal.feed(Array("\u{1B}_Ga=t,i=1,f=32,s=128,v=128;\(payload)\u{1B}\\".utf8))
        let data = try #require(terminal.grid.imagePlacements.image(KittyGraphics.ImageID(rawValue: 1)))
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.phys_footprint : 0
        }
        var report = "four-pane Kitty 128x128 RGBA storage, same bytes and device\n"
        for mode in [MTLStorageMode.managed, .shared] {
            let before = device.currentAllocatedSize, beforeFootprint = footprint()
            let start = DispatchTime.now().uptimeNanoseconds
            let renderers = (0..<4).map { _ in KittyImageRenderer(device: device, makeTexture: { descriptor in
                descriptor.storageMode = mode
                return device.makeTexture(descriptor: descriptor)
            }) }
            let textures = try renderers.map { renderer in
                try #require(renderer.texture(for: KittyGraphics.ImageID(rawValue: 1), data: data))
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            #expect(textures.allSatisfy { $0.storageMode == mode })
            withExtendedLifetime((renderers, textures)) {
                report += "\(mode): allocated \(textures.map(\.allocatedSize)), device delta \(Int64(device.currentAllocatedSize) - Int64(before)), footprint delta \(Int64(footprint()) - Int64(beforeFootprint)), decode/upload \(ms) ms\n"
            }
        }
        try report.write(toFile: "/tmp/corta-kitty-storage.txt", atomically: true, encoding: .utf8)
    }

}
