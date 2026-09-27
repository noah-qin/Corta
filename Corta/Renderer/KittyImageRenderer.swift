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
import CortaTerminal
import Foundation
import ImageIO
import Metal
import simd

/// Decodes Kitty graphics images into textures and draws each placement as
/// one instanced quad through `QuadRenderer`'s color pipeline, the one
/// color emoji use (`quad_fragment_color`). A placement is just a rect, so
/// no new pipeline.
///
/// **Decoding.** RGB/RGBA are reordered to premultiplied bgra by hand; PNG
/// goes through `CGImageSource` into a bgra `CGContext`. PNG dimensions
/// are read off the header and checked against
/// `KittyGraphics.maximumImageDimension`/`maximumImagePixels` before
/// decoding: a few header bytes can claim a 40 GB decode.
///
/// **Off the frame path.** `update(table:...)` (from
/// `TerminalRenderer.updateInstances`) only schedules decodes, which run on
/// `decodeScheduler` with the texture upload; `draw` and `texture(for:)` are
/// cache lookups. A placement still decoding draws nothing, and
/// `onImagesReady` asks for a frame when it lands. Placements provably
/// offscreen aren't decoded until they scroll in; a bare PNG with no known
/// cell extent decodes eagerly.
///
/// **Caching.** One texture per image id, pruned in `update` once nothing
/// places it (including the last placement). A re-transmission bumps the
/// table's per-image store generation, invalidating the cached texture.
///
/// **Budgets.** Per pane (`textureByteBudget`, evicting least-recently
/// used; an image over the whole budget is never cached) and app-wide
/// (`GlobalTextureBudget`: skipped, retried when its generation moves).
/// Decode and allocation failures draw nothing and are remembered per store
/// generation, so a re-transmission retries.
///
/// **Threading.** `update`, `draw` and the test seam run on the main
/// thread; decodes install from the scheduler's queue. All mutable state is
/// behind `lock`, held only for dictionary work, never across a decode or
/// an allocation — hence `@unchecked Sendable`. `onImagesReady` fires on
/// the installing thread.
///
/// **Test seam.** `makeTexture`, `decodeImage` and `decodeScheduler` are
/// injectable; `texture(for:data:)` runs the pipeline synchronously, and
/// `texture(for:)`, `cachedTextureBytes` and `textureCount` are internal
/// for inspection.
nonisolated final class KittyImageRenderer: @unchecked Sendable {
    private let makeTextureImpl: (MTLTextureDescriptor) -> MTLTexture?
    private let decodeImageImpl: (KittyGraphics.ImageData) -> DecodedImage?
    private let decodeScheduler: (@escaping @Sendable () -> Void) -> Void
    private let textureByteBudget: Int
    private let globalBudget: GlobalTextureBudget

    /// A background decode installed a texture; schedule a frame. Called on
    /// the installing thread.
    var onImagesReady: (() -> Void)?

    private let lock = NSLock()
    private var textures: [KittyGraphics.ImageID: MTLTexture] = [:]
    /// Cached texture sizes (`width * height * 4`).
    private var textureBytes: [KittyGraphics.ImageID: Int] = [:]
    /// Least-recently-used first: the eviction order.
    private var textureAccessOrder: [KittyGraphics.ImageID] = []
    /// Sum of `textureBytes`: this renderer's global-budget reservation.
    private var textureBytesCached = 0
    /// The store generation each texture was decoded from; a mismatch means a
    /// re-transmission. The test seam uses 0, real transmissions start at 1.
    private var textureGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    /// Decode or allocation failures by store generation, so a broken image
    /// isn't retried every frame but a re-transmission is.
    private var failedGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    /// Images skipped for a full global budget, with the budget generation
    /// seen; retried once it moves, since another pane's release is otherwise
    /// invisible here.
    private var budgetBlocked: [KittyGraphics.ImageID: (storeGeneration: UInt64, budgetGeneration: Int)] = [:]
    /// Running decodes and their store generation; a stale completion
    /// discards its result.
    private var inFlight: [KittyGraphics.ImageID: UInt64] = [:]

    var textureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return textures.count
    }

    var cachedTextureBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return textureBytesCached
    }

    init(
        device: MTLDevice,
        textureByteBudget: Int = KittyGraphics.maximumPaneTextureBytes,
        globalBudget: GlobalTextureBudget = .shared,
        decodeImage: ((KittyGraphics.ImageData) -> DecodedImage?)? = nil,
        decodeScheduler: ((@escaping @Sendable () -> Void) -> Void)? = nil,
        // Last, so a trailing closure binds here.
        makeTexture: ((MTLTextureDescriptor) -> MTLTexture?)? = nil
    ) {
        self.textureByteBudget = textureByteBudget
        self.globalBudget = globalBudget
        self.makeTextureImpl = makeTexture ?? { device.makeTexture(descriptor: $0) }
        self.decodeImageImpl = decodeImage ?? Self.decode
        self.decodeScheduler = decodeScheduler ?? {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        }
    }

    deinit {
        lock.lock()
        let bytes = textureBytesCached
        lock.unlock()
        globalBudget.release(bytes)
    }

    /// The per-frame entry point (never from `draw`, and never decodes
    /// inline): prunes unreferenced textures, drops re-transmitted ones, and
    /// schedules decodes for new or newly visible placements.
    func update(
        table: ImagePlacementTable, rows: Int, offset: Int, scrollbackTotalPushed: Int,
        cellWidth: Float, cellHeight: Float
    ) {
        let placements = table.orderedPlacements()
        let liveIDs = Set(placements.map(\.imageID))
        var toSchedule: [(KittyGraphics.ImageID, UInt64, KittyGraphics.ImageData)] = []

        lock.lock()
        for id in textures.keys where !liveIDs.contains(id) {
            releaseTextureLocked(id)
        }
        // The table keeps the bytes, so a later re-placement re-decodes.
        failedGenerations = failedGenerations.filter { liveIDs.contains($0.key) }
        budgetBlocked = budgetBlocked.filter { liveIDs.contains($0.key) }
        for id in inFlight.keys where !liveIDs.contains(id) {
            inFlight[id] = nil
        }

        for placement in placements {
            let id = placement.imageID
            guard let data = table.image(id),
                let generation = table.storeGeneration(for: id)
            else { continue }
            if textureGenerations[id] == generation, textures[id] != nil { continue }
            if textureGenerations[id] != generation, textures[id] != nil {
                releaseTextureLocked(id)
            }
            guard failedGenerations[id] != generation else { continue }
            if let inFlightGeneration = inFlight[id] {
                if inFlightGeneration == generation { continue }
                // Superseded mid-decode: orphan the old completion.
                inFlight[id] = nil
            }
            if let blocked = budgetBlocked[id], blocked.storeGeneration == generation {
                guard blocked.budgetGeneration != globalBudget.generation else { continue }
                budgetBlocked[id] = nil
            }
            guard Self.isPotentiallyVisible(
                placement, data: data, rows: rows, offset: offset,
                scrollbackTotalPushed: scrollbackTotalPushed, cellHeight: cellHeight)
            else { continue }
            inFlight[id] = generation
            toSchedule.append((id, generation, data))
        }
        lock.unlock()

        for (id, generation, data) in toSchedule {
            decodeScheduler { [weak self] in
                self?.decodeAndInstall(id: id, generation: generation, data: data)
            }
        }
    }

    /// Conservative check for scheduling only: provably offscreen placements
    /// wait. A PNG without `c=`/`r=` has no known extent and answers true, or
    /// it would never decode. `draw` checks exactly.
    private static func isPotentiallyVisible(
        _ placement: KittyGraphics.Placement, data: KittyGraphics.ImageData,
        rows: Int, offset: Int, scrollbackTotalPushed: Int, cellHeight: Float
    ) -> Bool {
        let placementRows: Int?
        if let rows = placement.rows {
            placementRows = rows
        } else if data.height > 0 {
            placementRows = max(1, Int((Float(data.height) / cellHeight).rounded(.up)))
        } else {
            placementRows = nil
        }
        guard let placementRows else { return true }
        // `totalPushed`, not `.count` (`TerminalRenderer.selectionQuads`).
        let viewportRow =
            ScrollbackCoordinates.reanchoredRow(
                placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotalPushed) + offset
        return viewportRow + placementRows > 0 && viewportRow < rows
    }

    /// The decode, allocation and upload, on `decodeScheduler` (or inline for
    /// the test seam).
    private func decodeAndInstall(
        id: KittyGraphics.ImageID, generation: UInt64, data: KittyGraphics.ImageData
    ) {
        let decoded = decodeImageImpl(data)
        var installed = false
        lock.lock()
        if generation == 0 {
            installed = installLocked(id: id, generation: generation, decoded: decoded)
        } else if inFlight[id] == generation {
            inFlight[id] = nil
            installed = installLocked(id: id, generation: generation, decoded: decoded)
        }
        // Otherwise this generation went away mid-decode; discard. Only the
        // matching branch may clear `inFlight`, or a stale completion would
        // clear a newer decode's entry.
        lock.unlock()
        if installed { onImagesReady?() }
    }

    /// Installs a decoded image; caller holds `lock`. Returns whether it did.
    private func installLocked(
        id: KittyGraphics.ImageID, generation: UInt64, decoded: DecodedImage?
    ) -> Bool {
        guard let decoded else {
            failedGenerations[id] = generation
            return false
        }
        let bytes = decoded.width * decoded.height * 4
        // Over the whole pane budget: fail permanently rather than evict
        // everything every frame.
        guard bytes <= textureByteBudget else {
            failedGenerations[id] = generation
            return false
        }
        while textureBytesCached + bytes > textureByteBudget, let oldest = textureAccessOrder.first {
            releaseTextureLocked(oldest)
        }
        guard globalBudget.tryReserve(bytes) else {
            // The global budget is transient: retry when its generation moves.
            budgetBlocked[id] = (generation, globalBudget.generation)
            return false
        }
        guard let texture = makeTexture(from: decoded) else {
            globalBudget.release(bytes)
            failedGenerations[id] = generation
            return false
        }
        releaseTextureLocked(id)
        textures[id] = texture
        textureBytes[id] = bytes
        textureGenerations[id] = generation
        textureBytesCached += bytes
        textureAccessOrder.append(id)
        return true
    }

    /// Drops one texture, returning its bytes to both budgets; caller holds
    /// `lock`.
    private func releaseTextureLocked(_ id: KittyGraphics.ImageID) {
        guard textures.removeValue(forKey: id) != nil, let bytes = textureBytes.removeValue(forKey: id)
        else { return }
        textureGenerations[id] = nil
        textureAccessOrder.removeAll { $0 == id }
        textureBytesCached -= bytes
        globalBudget.release(bytes)
    }

    /// Draws visible placements in z-index then transmission order, placed
    /// like `TerminalRenderer.selectionQuads`. Cache reads only: an uncached
    /// placement draws nothing this frame.
    func draw(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int, rect: CGRect, drawableSize: CGSize,
        quadRenderer: any TerminalRenderBackend, renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        forEachVisiblePlacement(
            table: table, cellWidth: cellWidth, cellHeight: cellHeight, rows: rows,
            offset: offset, scrollbackTotalPushed: scrollbackTotalPushed
        ) { instance, texture in
            quadRenderer.drawColorQuads(
                [instance], atlas: texture, rect: rect, drawableSize: drawableSize,
                renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
            // Passes after the first never clear (`TerminalRenderer.draw`).
            renderPassDescriptor.colorAttachments[0].loadAction = .load
        }
    }

    /// The Metal 4 `draw`, into the backend's open frame.
    func draw(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int, rect: CGRect, drawableSize: CGSize,
        metal4 backend: any Metal4FrameBackend
    ) {
        forEachVisiblePlacement(
            table: table, cellWidth: cellWidth, cellHeight: cellHeight, rows: rows,
            offset: offset, scrollbackTotalPushed: scrollbackTotalPushed
        ) { instance, texture in
            backend.drawColorQuads(
                [instance], atlas: texture, rect: rect, drawableSize: drawableSize)
        }
    }

    /// The culling and quad math both `draw` paths share, so they never
    /// disagree about what draws.
    private func forEachVisiblePlacement(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int,
        body: (QuadInstance, MTLTexture) -> Void
    ) {
        let placements = table.orderedPlacements().sorted { $0.zIndex < $1.zIndex }
        guard !placements.isEmpty else { return }

        for placement in placements {
            guard let texture = texture(for: placement.imageID) else { continue }

            // `totalPushed`, not `.count` (`TerminalRenderer.selectionQuads`).
            let viewportRow =
                ScrollbackCoordinates.reanchoredRow(
                    placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotalPushed) + offset
            let columns = placement.columns ?? max(1, Int((Float(texture.width) / cellWidth).rounded(.up)))
            let placementRows =
                placement.rows ?? max(1, Int((Float(texture.height) / cellHeight).rounded(.up)))
            guard viewportRow + placementRows > 0, viewportRow < rows else { continue }

            let instance = QuadInstance(
                origin: .init(Float(placement.column) * cellWidth, Float(viewportRow) * cellHeight),
                size: .init(Float(columns) * cellWidth, Float(placementRows) * cellHeight),
                color: .one, uvRect: .init(0, 0, 1, 1))
            body(instance, texture)
        }
    }

    /// The cached texture, or nil: no decode, allocation or scheduling.
    func texture(for id: KittyGraphics.ImageID) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard let texture = textures[id] else { return nil }
        textureAccessOrder.removeAll { $0 == id }
        textureAccessOrder.append(id)
        return texture
    }

    /// Test seam: decodes and installs inline at generation 0. Production
    /// uses `update`.
    func texture(for id: KittyGraphics.ImageID, data: KittyGraphics.ImageData) -> MTLTexture? {
        lock.lock()
        if let texture = textures[id], textureGenerations[id] == 0 {
            textureAccessOrder.removeAll { $0 == id }
            textureAccessOrder.append(id)
            lock.unlock()
            return texture
        }
        if failedGenerations[id] == 0 {
            lock.unlock()
            return nil
        }
        if let blocked = budgetBlocked[id], blocked.storeGeneration == 0 {
            guard blocked.budgetGeneration != globalBudget.generation else {
                lock.unlock()
                return nil
            }
            budgetBlocked[id] = nil
        }
        lock.unlock()
        decodeAndInstall(id: id, generation: 0, data: data)
        return texture(for: id)
    }

    /// Premultiplied bgra plus real dimensions, which for PNG may differ from
    /// `s=`/`v=`. Internal for the `decodeImage` hook.
    struct DecodedImage {
        var width: Int
        var height: Int
        var bgra: [UInt8]
    }

    static func decode(_ data: KittyGraphics.ImageData) -> DecodedImage? {
        switch data.format {
        case .rgb:
            return decodeRaw(data, bytesPerPixel: 3)
        case .rgba:
            return decodeRaw(data, bytesPerPixel: 4)
        case .png:
            return decodePNG(data.bytes)
        }
    }

    private static func decodeRaw(_ data: KittyGraphics.ImageData, bytesPerPixel: Int) -> DecodedImage? {
        let width = data.width, height = data.height
        guard width > 0, height > 0, data.bytes.count == width * height * bytesPerPixel else { return nil }
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        data.bytes.withUnsafeBufferPointer { source in
            bgra.withUnsafeMutableBufferPointer { destination in
                for pixel in 0..<(width * height) {
                    let s = pixel * bytesPerPixel
                    let d = pixel * 4
                    let r = source[s], g = source[s + 1], b = source[s + 2]
                    let a = bytesPerPixel == 4 ? source[s + 3] : 255
                    // Premultiplied for `quad_fragment_color`; a no-op for RGB.
                    let alpha = Float(a) / 255
                    destination[d] = UInt8((Float(b) * alpha).rounded())
                    destination[d + 1] = UInt8((Float(g) * alpha).rounded())
                    destination[d + 2] = UInt8((Float(r) * alpha).rounded())
                    destination[d + 3] = a
                }
            }
        }
        return DecodedImage(width: width, height: height, bgra: bgra)
    }

    private static func decodePNG(_ bytes: [UInt8]) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil) else { return nil }
        // Dimensions come off the header before anything decodes, so the caps
        // stop a hostile declaration before the work starts.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= KittyGraphics.maximumImageDimension, height <= KittyGraphics.maximumImageDimension,
            width <= KittyGraphics.maximumImagePixels / height,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == width, image.height == height
        else { return nil }
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bgra, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // No CTM flip, as in `GlyphAtlas.rasterizeColor`.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(width: width, height: height, bgra: bgra)
    }

    private func makeTexture(from decoded: DecodedImage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: decoded.width, height: decoded.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = makeTextureImpl(descriptor) else { return nil }
        decoded.bgra.withUnsafeBytes { raw in
            // Non-empty (`decode` rejects zero), but never trap.
            guard let baseAddress = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, decoded.width, decoded.height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: decoded.width * 4)
        }
        return texture
    }
}

/// The app-wide image texture budget: VRAM is shared, and per-pane caps
/// don't stop N panes exhausting it. Renderers reserve on cache and
/// release on eviction, prune and `deinit`.
nonisolated final class GlobalTextureBudget: @unchecked Sendable {
    static let shared = GlobalTextureBudget(limit: KittyGraphics.maximumGlobalTextureBytes)

    let limit: Int
    private let lock = NSLock()
    private var reserved = 0
    private var releaseCount = 0

    /// Bumped on every release, so a renderer that skipped an image learns
    /// cheaply that space may exist.
    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return releaseCount
    }

    init(limit: Int) {
        self.limit = limit
    }

    func tryReserve(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes <= limit - reserved else { return false }
        reserved += bytes
        return true
    }

    func release(_ bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        reserved -= bytes
        releaseCount &+= 1
    }
}
