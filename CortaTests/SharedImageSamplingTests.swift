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

import CoreGraphics
import Foundation
import Metal
import Testing

@testable import Corta

@Suite(
    .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct SharedImageSamplingTests {
    @Test func linearVersusTiledSampling() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pixels = try #require(
            ImageDecoderProcess.SharedPixels(
                width: 4096, height: 4096,
                alignment: device.minimumLinearTextureAlignment(for: .bgra8Unorm)))
        memset(pixels.address, 255, pixels.length)
        let linear = try #require(pixels.texture(device: device, width: 4096, height: 4096))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 4096, height: 4096, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let tiled = try #require(device.makeTexture(descriptor: descriptor))
        tiled.replace(
            region: MTLRegionMake2D(0, 0, 4096, 4096), mipmapLevel: 0,
            withBytes: pixels.address, bytesPerRow: pixels.bytesPerRow)
        descriptor.storageMode = .private
        let privateTexture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let copy = try #require(queue.makeCommandBuffer())
        let blit = try #require(copy.makeBlitCommandEncoder())
        blit.copy(
            from: linear, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 4096, height: 4096, depth: 1),
            to: privateTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        copy.commit()
        copy.waitUntilCompleted()
        let backend = try Metal4Backend(device: device)
        let target = MetalRenderTarget.make(device: device, width: 1024, height: 768)
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let quads = [
            QuadInstance(origin: .zero, size: .init(1024, 768), color: .one, atlasIndex: .max)
        ]
        var report =
            "4096x4096 BGRA sampled to 1024x768; submission-to-completion, same gpu metric boundary\n"
        var timings: [String: [Double]] = ["linear": [], "tiled": [], "private": []]
        for index in 0..<65 {
            let variants = [("linear", linear), ("tiled", tiled), ("private", privateTexture)]
            let offset = index % variants.count
            let ordered = Array(variants[offset...] + variants[..<offset])
            for (name, texture) in ordered {
                let start = DispatchTime.now().uptimeNanoseconds
                #expect(
                    backend.renderFrameAndWait(into: target) { backend in
                        backend.drawColorQuads(
                            quads, atlas: texture, rect: rect, drawableSize: rect.size,
                            imageUVRect: .init(0, 0, 1, 1))
                    })
                if index >= 5 {
                    timings[name, default: []].append(
                        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
            }
        }
        for name in ["linear", "tiled", "private"] {
            let samples = timings[name]!.sorted()
            report += "\(name): p50=\(samples[30]) p95=\(samples[57]) p99=\(samples[59]) ms\n"
        }
        try report.write(
            toFile: "/tmp/corta-linear-sampling.txt", atomically: true, encoding: .utf8)
    }
}
