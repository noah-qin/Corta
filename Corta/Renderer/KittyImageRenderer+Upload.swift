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
import Foundation
import Metal
import Synchronization

/// Transient decode failures, and the upload from decoded pixels to a texture.
nonisolated extension KittyImageRenderer {
    enum TextureUpload {
        case made(MTLTexture)
        /// Allocation or upload refused: this generation will not draw.
        case failed
        /// The GPU did not complete the upload in time; try again later.
        case gpuBusy
    }

    /// Waiting out a backoff. A failure of an older generation is forgotten.
    /// Caller holds `lock`.
    func isWaitingOutTransientFailureLocked(_ id: KittyGraphics.ImageID, generation: UInt64) -> Bool {
        guard let failure = transientFailures[id] else { return false }
        guard failure.generation == generation else {
            transientFailures[id] = nil
            return false
        }
        return ProcessInfo.processInfo.systemUptime < failure.retryAt
    }

    private func uploadCommandQueue() -> MTLCommandQueue? {
        lock.lock()
        defer { lock.unlock() }
        if uploadQueue == nil { uploadQueue = device.makeCommandQueue() }
        return uploadQueue
    }

    /// The delay before `id` is tried again, or nil once it has failed too many
    /// times to be worth asking: then it is failed for good, like a bad image.
    /// Caller holds `lock`.
    func noteTransientFailureLocked(id: KittyGraphics.ImageID, generation: UInt64) -> TimeInterval? {
        let attempts = transientFailures[id].map { $0.generation == generation ? $0.attempts : 0 } ?? 0
        guard attempts < Self.maximumTransientRetries else {
            transientFailures[id] = nil
            failedGenerations[id] = generation
            return nil
        }
        let delay = transientRetryDelay * Double(1 << attempts)
        transientFailures[id] = TransientFailure(
            generation: generation, attempts: attempts + 1,
            retryAt: ProcessInfo.processInfo.systemUptime + delay)
        return delay
    }

    func makeTexture(
        from decoded: DecodedImage, lease: TextureLease, permit: DecodePermit? = nil
    ) -> TextureUpload {
        if usesSharedPixels, let pixels = decoded.pixels {
            return uploadShared(pixels, decoded: decoded, lease: lease, permit: permit)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: decoded.width, height: decoded.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = makeTextureImpl(descriptor) else { return .failed }
        attach(lease, to: texture)
        decoded.bgra.withUnsafeBytes { raw in
            // Non-empty (`decode` rejects zero), but never trap.
            guard let baseAddress = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, decoded.width, decoded.height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: decoded.width * 4)
        }
        return .made(texture)
    }

    /// A GPU copy into a private texture, and the wait for it.
    private func uploadShared(
        _ pixels: ImageDecoderProcess.SharedPixels, decoded: DecodedImage, lease: TextureLease, permit: DecodePermit?
    ) -> TextureUpload {
        guard
            let linear = pixels.texture(
                device: device, width: decoded.width, height: decoded.height)
        else { return .failed }
        // Alternating same-device sampling found a slower median for linear
        // storage. One GPU copy keeps CPU pixels untouched and sampling tiled.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: decoded.width, height: decoded.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return .failed }
        guard let command = uploadCommandQueue()?.makeCommandBuffer(),
            let blit = command.makeBlitCommandEncoder()
        else { return .gpuBusy }
        attach(lease, to: texture)
        blit.copy(
            from: linear, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: decoded.width, height: decoded.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let finished = DispatchSemaphore(value: 0)
        let success = Atomic<Bool>(false)
        command.addCompletedHandler { buffer in
            success.store(buffer.status == .completed, ordering: .releasing)
            finished.signal()
        }
        command.commit()
        // Up to ten seconds of nothing but waiting, so not on a decode
        // permit: two uploads on a stuck GPU stopped every pane's images.
        let holdsWaitSlot = Self.uploadWaitBudget.tryReserve(1)
        defer { if holdsWaitSlot { Self.uploadWaitBudget.release(1) } }
        if holdsWaitSlot { permit?.release(whileWorking: self) }
        uploadWaitGate?()
        guard finished.wait(timeout: .now() + 10) == .success,
            success.load(ordering: .acquiring)
        else { return .gpuBusy }
        return .made(texture)
    }
}
