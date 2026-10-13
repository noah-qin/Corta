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
import ObjectiveC
import Synchronization
import simd

/// Decodes Kitty graphics images into textures and draws each placement as
/// one instanced quad through the colour pipeline, the one colour emoji use
/// (`quad_fragment_color`), in the frame's one render pass. A placement is just a rect, so
/// no new pipeline.
///
/// **Decoding.** RGB/RGBA are reordered to premultiplied bgra by hand; PNG
/// is decoded by `corta-image-decoder`, sandboxed, out of process
/// (`ImageDecoderProcess`), which reads the dimensions off the header and
/// checks them against `KittyGraphics.maximumImageDimension`/
/// `maximumImagePixels` before decoding: a few header bytes can claim a
/// 40 GB decode.
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
    private let device: MTLDevice
    private let usesSharedPixels: Bool
    /// Created on the first shared-pixel upload, under `lock`: a pane that
    /// never shows an image never owns a queue.
    private var uploadQueue: MTLCommandQueue?
    private let makeTextureImpl: (MTLTextureDescriptor) -> MTLTexture?
    private let decodeImageImpl: (KittyGraphics.ImageData) -> DecodedImage?
    private let decodeScheduler: (@escaping @Sendable () -> Void) -> Void
    private let textureByteBudget: Int
    private let globalBudget: GlobalTextureBudget
    private let paneBudget: GlobalTextureBudget
    private static let decodeBudget = GlobalTextureBudget(limit: 2)
    private static let decodeFinished = Notification.Name("Corta.imageDecodeFinished")
    private var decodeObserver: NSObjectProtocol?
    private final class TextureLeaseKey: Sendable {}
    private static let textureLeaseKey = TextureLeaseKey()

    /// A background decode installed a texture; schedule a frame. Called on
    /// the installing thread.
    var onImagesReady: (() -> Void)?

    private let lock = NSLock()
    private var textures: [KittyGraphics.ImageID: MTLTexture] = [:]
    /// Cached texture sizes (`width * height * 4`).
    private var textureBytes: [KittyGraphics.ImageID: Int] = [:]
    /// Least-recently-used first: the eviction order.
    private var textureAccessOrder: [KittyGraphics.ImageID] = []
    /// Sum of cached sizes; leases also charge textures retained after eviction.
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
    private var budgetBlocked: [KittyGraphics.ImageID: (
        storeGeneration: UInt64, globalGeneration: Int, paneGeneration: Int, visibilityGeneration: Int
    )] = [:]
    /// Images the last `update` found potentially on screen. Never evicted to
    /// make room: when visible images alone overflow the pane budget, evicting
    /// one to install another made the next frame decode it again, and the
    /// pair took turns for as long as both were on screen — a 64 MB decode a
    /// frame from a few kilobytes of output. The overflow waits instead.
    private var visibleIDs: Set<KittyGraphics.ImageID> = []
    /// Bumped when `visibleIDs` changes, which retries what overflow blocked.
    private var visibilityGeneration = 0
    /// Bytes a PNG decoded to, by store generation: its size is unknown until
    /// then, and knowing it lets a blocked PNG wait without decoding again.
    private var knownDecodedBytes: [KittyGraphics.ImageID: (generation: UInt64, bytes: Int)] = [:]
    /// Running decodes and their store generation; a stale completion
    /// discards its result.
    private var inFlight: [KittyGraphics.ImageID: UInt64] = [:]
    private var desiredGenerations: [KittyGraphics.ImageID: UInt64] = [:]

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
        self.device = device
        self.usesSharedPixels = makeTexture == nil
        self.textureByteBudget = textureByteBudget
        self.globalBudget = globalBudget
        self.paneBudget = GlobalTextureBudget(limit: textureByteBudget)
        self.makeTextureImpl = makeTexture ?? { device.makeTexture(descriptor: $0) }
        self.decodeImageImpl = decodeImage ?? { data in
                Self.decode(data, alignment: device.minimumLinearTextureAlignment(for: .bgra8Unorm))
            }
        self.decodeScheduler = decodeScheduler ?? {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        }
        decodeObserver = NotificationCenter.default.addObserver(
            forName: Self.decodeFinished, object: nil, queue: nil
        ) { [weak self] _ in self?.onImagesReady?() }
    }

    deinit {
        if let decodeObserver { NotificationCenter.default.removeObserver(decodeObserver) }
        for texture in textures.values { Self.lease(of: texture)?.retire() }
        // Reservations belong to textures, including those retained by Metal.
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
        var toSchedule: [(KittyGraphics.ImageID, UInt64, KittyGraphics.ImageData, DecodePermit)] = []

        lock.lock()
        for id in textures.keys where !liveIDs.contains(id) {
            releaseTextureLocked(id)
        }
        // The table keeps the bytes, so a later re-placement re-decodes.
        failedGenerations = failedGenerations.filter { liveIDs.contains($0.key) }
        budgetBlocked = budgetBlocked.filter { liveIDs.contains($0.key) }
        desiredGenerations = Dictionary(uniqueKeysWithValues: liveIDs.compactMap { id in
            table.storeGeneration(for: id).map { (id, $0) }
        })
        // One pass, and none at all (no allocation) for a pane without images.
        var visible = Set<KittyGraphics.ImageID>()
        for placement in placements where !visible.contains(placement.imageID) {
            guard let data = table.image(placement.imageID),
                Self.isPotentiallyVisible(
                    placement, pixelHeight: data.height > 0 ? data.height : textures[placement.imageID]?.height,
                    rows: rows, offset: offset,
                    scrollbackTotalPushed: scrollbackTotalPushed, cellHeight: cellHeight)
            else { continue }
            visible.insert(placement.imageID)
        }
        knownDecodedBytes = knownDecodedBytes.filter { liveIDs.contains($0.key) }
        if visible != visibleIDs {
            visibleIDs = visible
            visibilityGeneration &+= 1
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
            // A replacement cannot orphan an actual queued/running job.
            guard inFlight[id] == nil else { continue }
            if let blocked = budgetBlocked[id], blocked.storeGeneration == generation {
                guard blocked.globalGeneration != globalBudget.generation
                    || blocked.paneGeneration != paneBudget.generation
                    || blocked.visibilityGeneration != visibilityGeneration else { continue }
                budgetBlocked[id] = nil
            }
            guard visible.contains(id) else { continue }
            guard data.bytes.count <= 64 * 1024 * 1024 else {
                failedGenerations[id] = generation
                continue
            }
            // Known not to fit beside the visible textures, which are never
            // evicted: wait without decoding — a blocked image retried on every
            // visibility change was a full decode each time.
            if let needed = decodedBytes(of: data, id: id, generation: generation),
                needed > textureByteBudget - visibleTextureBytes(excluding: id)
            {
                budgetBlocked[id] = (
                    generation, globalBudget.generation, paneBudget.generation, visibilityGeneration)
                continue
            }
            guard Self.decodeBudget.tryReserve(1) else { continue }
            inFlight[id] = generation
            toSchedule.append((id, generation, data, DecodePermit()))
        }
        lock.unlock()

        for (id, generation, data, permit) in toSchedule {
            decodeScheduler { [weak self] in
                defer { permit.release() }
                self?.decodeAndInstall(id: id, generation: generation, data: data)
            }
        }
    }

    /// Texture bytes an image needs, before decoding it: from the header for
    /// raw pixels, from an earlier decode for a PNG. `nil` until a PNG decodes.
    private func decodedBytes(
        of data: KittyGraphics.ImageData, id: KittyGraphics.ImageID, generation: UInt64
    ) -> Int? {
        if data.format != .png, data.width > 0, data.height > 0 { return data.width * data.height * 4 }
        guard let known = knownDecodedBytes[id], known.generation == generation else { return nil }
        return known.bytes
    }

    /// What the visible textures other than `id` hold; caller holds `lock`.
    private func visibleTextureBytes(excluding id: KittyGraphics.ImageID) -> Int {
        visibleIDs.reduce(0) { $0 + ($1 == id ? 0 : textureBytes[$1] ?? 0) }
    }

    /// Conservative check for scheduling only: provably offscreen placements
    /// wait. A PNG without `c=`/`r=` has no known extent until it has decoded
    /// once (`pixelHeight` is then its texture's) and answers true, or it would
    /// never decode — nor, being "visible", ever be evicted. `draw` checks
    /// exactly.
    private static func isPotentiallyVisible(
        _ placement: KittyGraphics.Placement, pixelHeight: Int?,
        rows: Int, offset: Int, scrollbackTotalPushed: Int, cellHeight: Float
    ) -> Bool {
        let placementRows: Int?
        if let rows = placement.rows {
            placementRows = rows
        } else if let pixelHeight, pixelHeight > 0 {
            placementRows = max(1, Int((Float(pixelHeight) / cellHeight).rounded(.up)))
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
        if generation != 0 {
            lock.lock()
            let relevant = desiredGenerations[id] == generation
            if !relevant { inFlight[id] = nil }
            lock.unlock()
            guard relevant else { return }
        }
        let decoded = decodeImageImpl(data)
        lock.lock()
        guard isRelevantLocked(id: id, generation: generation) else {
            if inFlight[id] == generation { inFlight[id] = nil }
            lock.unlock()
            return
        }
        let lease = reserveLocked(id: id, generation: generation, decoded: decoded)
        if lease == nil, inFlight[id] == generation { inFlight[id] = nil }
        lock.unlock()
        guard let decoded, let lease else { return }
        // Allocation and GPU completion must never hold the cache lock: a
        // hung upload cannot stall a window's render thread or bounded teardown.
        let made = makeTexture(from: decoded, lease: lease)
        lock.lock()
        let stillRelevant = isRelevantLocked(id: id, generation: generation)
        if inFlight[id] == generation { inFlight[id] = nil }
        var installed = false
        if stillRelevant, case .made(let texture) = made {
            releaseTextureLocked(id)
            textures[id] = texture
            textureBytes[id] = lease.bytes
            textureGenerations[id] = generation
            textureBytesCached += lease.bytes
            textureAccessOrder.append(id)
            installed = true
        } else {
            lease.retire()
            switch made {
            case .made: break
            case .failed where stillRelevant:
                failedGenerations[id] = generation
            case .gpuBusy where stillRelevant:
                // A GPU that did not finish the upload in time is transient,
                // not a broken image: retry as an image that met a full
                // budget does, once a texture is freed or visibility moves.
                budgetBlocked[id] = (
                    generation, globalBudget.generation, paneBudget.generation, visibilityGeneration)
            default: break
            }
        }
        lock.unlock()
        if installed, generation == 0 { onImagesReady?() }
    }

    /// Still wanted: a synchronous request (generation 0), or the running
    /// decode of the generation the table now holds. Caller holds `lock`.
    private func isRelevantLocked(id: KittyGraphics.ImageID, generation: UInt64) -> Bool {
        generation == 0 || (inFlight[id] == generation && desiredGenerations[id] == generation)
    }

    private enum TextureUpload {
        case made(MTLTexture)
        /// Allocation or upload refused: this generation will not draw.
        case failed
        /// The GPU did not complete the upload in time; try again later.
        case gpuBusy
    }

    /// Reserves admission; caller holds `lock`. GPU work happens after unlocking.
    private func reserveLocked(
        id: KittyGraphics.ImageID, generation: UInt64, decoded: DecodedImage?
    ) -> TextureLease? {
        guard let decoded else {
            failedGenerations[id] = generation
            return nil
        }
        let bytes = decoded.width * decoded.height * 4
        knownDecodedBytes[id] = (generation, bytes)
        // Over the whole pane budget: fail permanently rather than evict
        // everything every frame.
        guard bytes <= textureByteBudget else {
            failedGenerations[id] = generation
            return nil
        }
        releaseTextureLocked(id)
        while paneBudget.reservedBytes + bytes > textureByteBudget,
            let oldest = textureAccessOrder.first(where: { !visibleIDs.contains($0) })
        {
            releaseTextureLocked(oldest)
        }
        guard paneBudget.tryReserve(bytes) else {
            budgetBlocked[id] = (
                generation, globalBudget.generation, paneBudget.generation, visibilityGeneration)
            return nil
        }
        guard globalBudget.tryReserve(bytes) else {
            paneBudget.release(bytes)
            // The global budget is transient: retry when its generation moves.
            budgetBlocked[id] = (
                generation, globalBudget.generation, paneBudget.generation, visibilityGeneration)
            return nil
        }
        // The shared mapping is not charged here: it is released once its
        // pixels are copied to the private texture these bytes account for.
        return TextureLease(bytes: bytes, pane: paneBudget, global: globalBudget)
    }

    /// Drops cache ownership; the texture's final owner returns quota.
    /// Caller holds `lock`.
    private func releaseTextureLocked(_ id: KittyGraphics.ImageID) {
        guard let texture = textures.removeValue(forKey: id), let bytes = textureBytes.removeValue(forKey: id)
        else { return }
        Self.lease(of: texture)?.retire()
        textureGenerations[id] = nil
        textureAccessOrder.removeAll { $0 == id }
        textureBytesCached -= bytes
    }

    private static func lease(of texture: MTLTexture) -> TextureLease? {
        objc_getAssociatedObject(texture, Unmanaged.passUnretained(textureLeaseKey).toOpaque()) as? TextureLease
    }

    /// Retry while evicted textures await retirement; cached images alone
    /// must not create a completion/redraw loop on idle panes.
    func noteGPUCompletion() {
        if paneBudget.retiredBytes > 0 { onImagesReady?() }
    }

    /// Draws visible placements in z-index then transmission order, placed
    /// like `TerminalRenderer.selectionQuads`, into the backend's open
    /// frame. Cache reads only: an uncached placement draws nothing this
    /// frame.
    func draw(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int, rect: CGRect, drawableSize: CGSize,
        backend: Metal4Backend, drawable: MTLDrawable? = nil
    ) {
        forEachVisiblePlacement(
            table: table, cellWidth: cellWidth, cellHeight: cellHeight, rows: rows,
            offset: offset, scrollbackTotalPushed: scrollbackTotalPushed
        ) { instance, texture, sourceUVRect, receivedAt in
            backend.drawColorQuads(
                [instance], atlas: texture, rect: rect, drawableSize: drawableSize, imageUVRect: sourceUVRect, transient: true)
            if RenderMetrics.isEnabled, let receivedAt, let drawable {
                RenderMetrics.noteImagePresent(of: drawable, receivedAt: receivedAt)
            }
        }
    }

    /// The culling and quad math.
    private func forEachVisiblePlacement(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int,
        body: (QuadInstance, MTLTexture, SIMD4<Float>, TimeInterval?) -> Void
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
                color: .one, atlasIndex: .max)
            // The arrival time is a metric only: no image lookup per frame without it.
            let receivedAt = RenderMetrics.isEnabled ? table.image(placement.imageID)?.receivedAt : nil
            body(instance, texture, Self.sourceUVRect(for: placement), receivedAt)
        }
    }

    static func sourceUVRect(for placement: KittyGraphics.Placement) -> SIMD4<Float> {
        .init(0, placement.sourceTop, 1, placement.sourceBottom - placement.sourceTop)
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
            guard blocked.globalGeneration != globalBudget.generation
                || blocked.paneGeneration != paneBudget.generation else {
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
        private var packed: [UInt8]?
        var pixels: ImageDecoderProcess.SharedPixels?
        var bgra: [UInt8] { packed ?? pixels?.packedBytes(width: width, height: height) ?? [] }
        init(width: Int, height: Int, bgra: [UInt8]) {
            self.width = width
            self.height = height
            self.packed = bgra
        }
        init(width: Int, height: Int, pixels: ImageDecoderProcess.SharedPixels) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    private final class TextureLease {
        let bytes: Int
        let pane: GlobalTextureBudget
        let global: GlobalTextureBudget
        private var retired = false
        init(bytes: Int, pane: GlobalTextureBudget, global: GlobalTextureBudget) {
            self.bytes = bytes
            self.pane = pane
            self.global = global
        }
        func retire() {
            guard !retired else { return }
            retired = true
            pane.markRetired(bytes)
            global.markRetired(bytes)
        }
        deinit {
            pane.release(bytes, retired: retired)
            global.release(bytes, retired: retired)
            NotificationCenter.default.post(name: KittyImageRenderer.decodeFinished, object: nil)
        }
    }

    /// Scheduler abandonment and renderer teardown return admission too.
    private final class DecodePermit: Sendable {
        private let released = Atomic<Bool>(false)
        func release() {
            guard !released.exchange(true, ordering: .acquiringAndReleasing) else { return }
            KittyImageRenderer.decodeBudget.release(1)
            NotificationCenter.default.post(name: KittyImageRenderer.decodeFinished, object: nil)
        }
        deinit { release() }
    }

    static func decode(_ data: KittyGraphics.ImageData, alignment: Int = 256) -> DecodedImage? {
        switch data.format {
        case .rgb:
            return decodeRaw(data, bytesPerPixel: 3, alignment: alignment)
        case .rgba:
            return decodeRaw(data, bytesPerPixel: 4, alignment: alignment)
        case .png:
            return decodePNG(data.bytes, alignment: alignment)
        }
    }

    private static func decodeRaw(
        _ data: KittyGraphics.ImageData, bytesPerPixel: Int,
        alignment: Int
    ) -> DecodedImage? {
        let width = data.width
        let height = data.height
        guard KittyGraphics.dimensionsFit(width: width, height: height),
            data.bytes.count == width * height * bytesPerPixel,
            let pixels = ImageDecoderProcess.SharedPixels(
                width: width, height: height, alignment: alignment, shared: false)
        else { return nil }
        let destination = pixels.address.assumingMemoryBound(to: UInt8.self)
        data.bytes.withUnsafeBufferPointer { source in
            for row in 0..<height {
                for column in 0..<width {
                    let s = (row * width + column) * bytesPerPixel
                    let d = row * pixels.bytesPerRow + column * 4
                    let alpha = bytesPerPixel == 4 ? source[s + 3] : 255
                    let factor = Float(alpha) / 255
                    destination[d] = UInt8((Float(source[s + 2]) * factor).rounded())
                    destination[d + 1] = UInt8((Float(source[s + 1]) * factor).rounded())
                    destination[d + 2] = UInt8((Float(source[s]) * factor).rounded())
                    destination[d + 3] = alpha
                }
            }
        }
        return DecodedImage(width: width, height: height, pixels: pixels)
    }

    /// The eight bytes every PNG starts with (RFC 2083 §3.1).
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// `f=100` is PNG and nothing else. `CGImageSource` sniffs content, so
    /// unchecked any output could reach every ImageIO parser — TIFF, PSD,
    /// HEIC and the rest — under the name of a PNG: the signature is checked
    /// here, and the decoder process pins the type and the header's
    /// dimensions before it decodes. ImageIO itself runs only in that
    /// process, sandboxed (`ImageDecoderProcess`).
    static func decodePNG(_ bytes: [UInt8], alignment: Int = 256) -> DecodedImage? {
        guard bytes.starts(with: pngSignature), let decoded = ImageDecoderProcess.decodePNG(bytes, alignment: alignment)
        else { return nil }
        return DecodedImage(width: decoded.width, height: decoded.height, pixels: decoded.pixels)
    }

    /// A texture is born carrying its lease: MTL4 retains textures past cache
    /// eviction (and a timed-out blit past this call), so whoever holds it
    /// last returns the quota.
    private func attach(_ lease: TextureLease, to texture: MTLTexture) {
        objc_setAssociatedObject(
            texture, Unmanaged.passUnretained(Self.textureLeaseKey).toOpaque(), lease,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func uploadCommandQueue() -> MTLCommandQueue? {
        lock.lock()
        defer { lock.unlock() }
        if uploadQueue == nil { uploadQueue = device.makeCommandQueue() }
        return uploadQueue
    }

    private func makeTexture(from decoded: DecodedImage, lease: TextureLease) -> TextureUpload {
        if usesSharedPixels, let pixels = decoded.pixels {
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
            guard finished.wait(timeout: .now() + 10) == .success,
                success.load(ordering: .acquiring)
            else { return .gpuBusy }
            return .made(texture)
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
}

/// The app-wide image texture budget: VRAM is shared, and per-pane caps
/// don't stop N panes exhausting it. Texture leases release reservations
/// only when the last texture owner disappears, including GPU retention.
nonisolated final class GlobalTextureBudget: Sendable {
    static let shared = GlobalTextureBudget(limit: KittyGraphics.maximumGlobalTextureBytes)

    let limit: Int

    private struct State {
        var reserved = 0
        var retired = 0
        var releaseCount = 0
    }

    private let state = Mutex(State())

    /// Bumped on every release, so a renderer that skipped an image learns
    /// cheaply that space may exist.
    var generation: Int { state.withLock { $0.releaseCount } }

    var reservedBytes: Int { state.withLock { $0.reserved } }

    var retiredBytes: Int { state.withLock { $0.retired } }

    func markRetired(_ bytes: Int) {
        state.withLock { $0.retired += bytes }
    }

    init(limit: Int) {
        self.limit = limit
    }

    func tryReserve(_ bytes: Int) -> Bool {
        state.withLock { state in
            guard bytes <= limit - state.reserved else { return false }
            state.reserved += bytes
            return true
        }
    }

    func release(_ bytes: Int, retired wasRetired: Bool = false) {
        state.withLock { state in
            state.reserved -= bytes
            if wasRetired { state.retired -= bytes }
            state.releaseCount &+= 1
        }
    }
}
