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

import Metal

nonisolated extension Metal4Backend {
    /// One kind of draw: where its instances go, the pipeline that draws
    /// them, and the debug group it is labelled with.
    struct DrawPass {
        let ring: InstanceBufferRing
        let pipeline: MTLRenderPipelineState
        let label: String
    }

    /// Instance storage for one pipeline kind, one buffer per slot. Draws
    /// append (instances plus uniforms) to the frame's slot. A buffer grows
    /// geometrically and is reused every frame after, never shrunk
    /// (`PERFORMANCE.md` §3): a growing screen reallocates a handful of
    /// times, not every frame.
    final class InstanceBufferRing {
        private let device: MTLDevice
        private let residencySet: any MTLResidencySet
        private var buffers: [MTLBuffer?] = Array(repeating: nil, count: Metal4Backend.frameSlotCount)
        private var used = 0

        init(device: MTLDevice, residencySet: any MTLResidencySet) {
            self.device = device
            self.residencySet = residencySet
        }

        func beginFrame() {
            used = 0
        }

        /// Appends instances plus uniforms to `slot`, returning GPU addresses.
        /// Growth replaces the buffer rather than write memory an earlier
        /// draw of this frame still reads.
        func append(
            instances: UnsafeRawBufferPointer, uniforms: QuadUniforms, atlasRects: [SIMD4<UInt16>], slot: Int,
            retire: (MTLBuffer) -> Void
        ) -> UploadAddresses? {
            guard let instanceBase = instances.baseAddress else { return nil }
            let instanceByteCount = instances.count
            let instanceOffset = Self.align(used)
            let uniformOffset = Self.align(instanceOffset + instanceByteCount)
            let rectOffset = Self.align(uniformOffset + MemoryLayout<QuadUniforms>.stride)
            let needed = rectOffset + atlasRects.count * MemoryLayout<SIMD4<UInt16>>.stride
            if buffers[slot] == nil || buffers[slot]!.length < needed {
                let newLength = max(needed, (buffers[slot]?.length ?? 0) * 2)
                guard
                    let fresh = device.makeBuffer(length: newLength, options: .storageModeShared)
                else { return nil }
                if let old = buffers[slot] {
                    // Stays resident until this frame completes: earlier draws
                    // recorded its addresses.
                    retire(old)
                }
                buffers[slot] = fresh
                residencySet.addAllocation(fresh)
                residencySet.commit()
            }
            guard let buffer = buffers[slot] else { return nil }
            var uniforms = uniforms
            buffer.contents().advanced(by: instanceOffset)
                .copyMemory(from: instanceBase, byteCount: instanceByteCount)
            withUnsafeBytes(of: &uniforms) { raw in
                guard let base = raw.baseAddress else { return }
                buffer.contents().advanced(by: uniformOffset)
                    .copyMemory(from: base, byteCount: raw.count)
            }
            atlasRects.withUnsafeBytes { raw in
                if let base = raw.baseAddress, !raw.isEmpty {
                    buffer.contents().advanced(by: rectOffset).copyMemory(from: base, byteCount: raw.count)
                }
            }
            used = needed
            return UploadAddresses(
                instances: buffer.gpuAddress + UInt64(instanceOffset),
                uniforms: buffer.gpuAddress + UInt64(uniformOffset),
                rects: buffer.gpuAddress + UInt64(atlasRects.isEmpty ? uniformOffset : rectOffset))
        }

        /// Where one draw's instances, uniforms and rectangle table landed.
        struct UploadAddresses {
            var instances: MTLGPUAddress
            var uniforms: MTLGPUAddress
            var rects: MTLGPUAddress
        }

        private static func align(_ offset: Int) -> Int {
            // SIMD members need 16-byte alignment in the constant address space.
            (offset + 15) & ~15
        }
    }
}
