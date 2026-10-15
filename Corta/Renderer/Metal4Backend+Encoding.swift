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

nonisolated extension Metal4Backend {
    // MARK: - Encoding

    func draw(
        _ instances: ContiguousArray<QuadInstance>,
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        atlasRects: [SIMD4<UInt16>] = [],
        atlasRectsVersion: UInt64? = nil,
        imageUVRect: SIMD4<Float> = .zero,
        rect: CGRect,
        drawableSize: CGSize,
        label: String,
        transientTexture: Bool = false
    ) {
        // The pass (and its clear) opened in `beginFrame`.
        guard let encoder, !instances.isEmpty else { return }

        guard let scissor = Self.scissor(for: rect, in: drawableSize) else { return }

        let uniforms = QuadUniforms(
            rectOrigin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            rectSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            atlasSize: SIMD2<Float>(Float(atlas?.width ?? 1), Float(atlas?.height ?? 1)),
            imageUVRect: imageUVRect
        )
        guard
            upload(
                instances, uniforms: uniforms, atlasRects: atlasRects, atlasRectsVersion: atlasRectsVersion,
                through: ring)
        else { return }
        if let atlas {
            makeResident(atlas, transient: transientTexture)
            argumentTable.setTexture(atlas.gpuResourceID, index: 0)
            argumentTable.setSamplerState(sampler.gpuResourceID, index: 0)
        }

        if lastPipeline !== pipeline {
            encoder.setRenderPipelineState(pipeline)
            lastPipeline = pipeline
        }
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        setScissorAndViewport(scissor, drawableSize: drawableSize, on: encoder)
        encoder.pushDebugGroup(label)
        encoder.drawPrimitives(
            primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4,
            instanceCount: instances.count)
        encoder.popDebugGroup()
    }

    /// The scissor that keeps every instance inside `rect`, clipped to the
    /// drawable; `nil` when nothing of it is on the drawable.
    private static func scissor(for rect: CGRect, in drawableSize: CGSize) -> MTLScissorRect? {
        let x = max(0, Int(rect.minX.rounded(.down)))
        let y = max(0, Int(rect.minY.rounded(.down)))
        let width = min(Int(rect.width.rounded(.up)), max(0, Int(drawableSize.width) - x))
        let height = min(Int(rect.height.rounded(.up)), max(0, Int(drawableSize.height) - y))
        guard width > 0, height > 0 else { return nil }
        return MTLScissorRect(x: x, y: y, width: width, height: height)
    }

    /// Copies the instances, uniforms and — unless the atlas's own table is
    /// current — its rectangles into this frame's slot of `ring`, and points
    /// the argument table at them. `false` when there was no room.
    private func upload(
        _ instances: ContiguousArray<QuadInstance>, uniforms: QuadUniforms, atlasRects: [SIMD4<UInt16>],
        atlasRectsVersion: UInt64?, through ring: InstanceBufferRing
    ) -> Bool {
        let instanceByteCount = MemoryLayout<QuadInstance>.stride * instances.count
        var tableAddress: MTLGPUAddress?
        if let atlasRectsVersion, !atlasRects.isEmpty {
            guard let address = rectangleTableAddress(atlasRects, version: atlasRectsVersion) else { return false }
            tableAddress = address
        }
        let copiedRects = tableAddress == nil ? atlasRects : []
        guard
            let addresses = instances.withUnsafeBytes({ raw -> (MTLGPUAddress, MTLGPUAddress, MTLGPUAddress)? in
                guard let base = raw.baseAddress else { return nil }
                return ring.append(
                    instances: base, instanceByteCount: instanceByteCount, uniforms: uniforms, atlasRects: copiedRects,
                    slot: currentSlot, device: device, residencySet: residencySet
                ) { [self] buffer in
                    retired.append((frame: frameNumber, allocation: buffer))
                }
            })
        else { return false }
        uploadedInstanceBytes += instanceByteCount
        uploadedRectangleBytes += copiedRects.count * MemoryLayout<SIMD4<UInt16>>.stride
        argumentTable.setAddress(addresses.0, index: 0)
        argumentTable.setAddress(addresses.1, index: 1)
        argumentTable.setAddress(tableAddress ?? addresses.2, index: 2)
        return true
    }

    /// Sets the scissor and the full-drawable viewport, each only when it
    /// differs from what the encoder already has.
    private func setScissorAndViewport(
        _ scissor: MTLScissorRect, drawableSize: CGSize, on encoder: any MTL4RenderCommandEncoder
    ) {
        let scissorIsCurrent =
            lastScissor.map {
                $0.x == scissor.x && $0.y == scissor.y
                    && $0.width == scissor.width && $0.height == scissor.height
            } ?? false
        if !scissorIsCurrent {
            encoder.setScissorRect(scissor)
            lastScissor = scissor
        }
        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableSize.width), height: Double(drawableSize.height),
            znear: 0, zfar: 1)
        let viewportIsCurrent =
            lastViewport.map {
                $0.originX == viewport.originX && $0.originY == viewport.originY
                    && $0.width == viewport.width && $0.height == viewport.height
                    && $0.znear == viewport.znear && $0.zfar == viewport.zfar
            } ?? false
        if !viewportIsCurrent {
            encoder.setViewport(viewport)
            lastViewport = viewport
        }
    }

    /// A texture nothing will bind again — an atlas texture replaced while
    /// frames still sampled it — leaves residency, and is released, once the
    /// last frame that bound it completes, without the grace period.
    func retireTexture(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        guard let entry = boundTextures[id] else { return }
        boundTextures[id] = (texture: entry.texture, lastFrame: entry.lastFrame, retentionFrames: 0)
    }

    /// See `boundTextures`.
    private func makeResident(_ texture: MTLTexture, transient: Bool) {
        let id = ObjectIdentifier(texture)
        if boundTextures[id] == nil {
            residencySet.addAllocation(texture)
            residencySet.commit()
        }
        boundTextures[id] = (texture: texture, lastFrame: frameNumber,
            retentionFrames: transient ? 0 : Self.textureRetentionFrames)
    }

    /// Releases retired resources whose retiring frame has completed.
    func dropRetired(through completed: UInt64) {
        var removedAny = false
        retired.removeAll { entry in
            guard entry.frame <= completed else { return false }
            residencySet.removeAllocation(entry.allocation)
            removedAny = true
            return true
        }
        let expiredTextures = boundTextures.filter {
            $0.value.lastFrame + $0.value.retentionFrames <= completed
        }
        for (id, entry) in expiredTextures {
            residencySet.removeAllocation(entry.texture)
            boundTextures.removeValue(forKey: id)
            removedAny = true
        }
        if removedAny { residencySet.commit() }
    }
}
