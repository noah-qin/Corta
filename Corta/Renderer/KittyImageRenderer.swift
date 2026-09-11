import CoreGraphics
import CortaTerminal
import Foundation
import ImageIO
import Metal
import simd

/// Decodes Kitty graphics image data (`KittyGraphics.ImageData`, M10) into
/// textures and draws each live placement as one instanced quad through
/// `QuadRenderer`'s existing color pipeline — the same one color emoji
/// draws through, since both are "sample a premultiplied bgra texture
/// verbatim" (`Shaders.metal`'s `quad_fragment_color`). No new pipeline, no
/// mesh shader: a placed image is geometrically nothing but a rect, and the
/// instanced-quad path already does exactly that — mesh shaders solve GPU-
/// side geometry generation for large primitive counts, and one quad per
/// placement is not that (`PERFORMANCE.md`'s reasoning against a third
/// pipeline for the ordinary text/background path applies here too: this
/// is not the bottleneck to build novel infrastructure for).
///
/// **Decoding (P05).** RGB/RGBA are already pixels — reordered to
/// premultiplied bgra by hand. PNG is decoded via `CGImageSource` into a
/// premultiplied bgra `CGContext`, the same technique
/// `GlyphAtlas.rasterizeColor` already uses for color emoji, reused here
/// rather than reinvented. PNG *dimensions* are read off the header
/// (`CGImageSourceCopyPropertiesAtIndex`) and checked against
/// `KittyGraphics.maximumImageDimension`/`maximumImagePixels` before any
/// decoding happens (S02) — a header claiming a 100000×100000 image is a
/// few dozen bytes on the wire but a 40GB decode, so the size is validated
/// before the work, not after.
///
/// None of that runs on the frame path. `TerminalRenderer.updateInstances`
/// calls `update(table:...)` once per frame, which only *schedules* decodes
/// for images that are new, newly visible, or superseded; the decode itself
/// — plus the texture allocation and upload that follow it — runs on
/// `decodeScheduler` (a background queue in production, synchronous in
/// tests), and `draw`/`texture(for:)` are pure cache lookups. A placement
/// whose decode is in flight simply draws nothing that frame; the
/// completion fires `onImagesReady`, which the shell wires to a redraw
/// request, so the image appears as soon as it exists rather than whenever
/// unrelated output happens to schedule a frame. Decodes for placements
/// provably outside the viewport are not scheduled at all — scrolling the
/// image back into view schedules it then. (A placement with no explicit
/// `c=`/`r=` and no transmitted dimensions — a bare PNG — has no knowable
/// cell extent before decoding, so it decodes eagerly rather than never.)
///
/// **Caching.** One texture per image id, decoded once and kept until that
/// id is no longer placed at all. Pruning runs in `update`, unconditionally
/// — including when the *last* placement disappears, which the old
/// draw-side prune never reached (it bailed out early on an empty table,
/// leaking the final image's texture and budget). A re-transmission that
/// reuses an id invalidates the old texture: `ImagePlacementTable` bumps a
/// per-image generation on every `store`, and a cached entry whose
/// generation no longer matches is dropped and re-decoded.
///
/// **Memory budgets (S02/S07).** Cached textures are bounded per pane
/// (`textureByteBudget`, defaulting to `KittyGraphics.maximumPaneTextureBytes`)
/// and application-wide (`GlobalTextureBudget`, up to
/// `KittyGraphics.maximumGlobalTextureBytes` across every pane). Over the
/// per-pane budget, the least-recently-used texture is evicted to make
/// room; an image larger than the whole budget is never cached. Over the
/// *global* budget the image is skipped but not failed permanently — it is
/// retried once the budget's generation moves (any release by any pane),
/// without paying a re-decode every frame while the budget stays full. A
/// texture allocation that fails outright is remembered like a
/// decode failure, and the placement simply draws nothing: the terminal
/// stays usable, the image does not appear. Failures and blocks are
/// recorded per store generation, so a re-transmission of the same id gets
/// a fresh attempt.
///
/// **Threading.** `update`, `draw` and the test seam run on the main
/// thread; decode completions install on a background queue. Every piece of
/// mutable cache state is guarded by `lock`, which is held only for
/// dictionary operations — never across a decode or an allocation.
/// `onImagesReady` fires on whatever thread installed the texture; the
/// shell's wiring hops to the main queue.
///
/// **Test seam.** `makeTexture` injects an allocation hook, `decodeImage`
/// a decode hook (a counting one proves the frame path never decodes), and
/// `decodeScheduler` a synchronous or queue-capturing scheduler.
/// `texture(for:data:)` drives the whole pipeline synchronously;
/// `texture(for:)`, `cachedTextureBytes` and `textureCount` are internal
/// rather than private so `CortaTests` can inspect the cache directly
/// without a render pass.
nonisolated final class KittyImageRenderer {
    private let makeTextureImpl: (MTLTextureDescriptor) -> MTLTexture?
    private let decodeImageImpl: (KittyGraphics.ImageData) -> DecodedImage?
    private let decodeScheduler: (@escaping () -> Void) -> Void
    private let textureByteBudget: Int
    private let globalBudget: GlobalTextureBudget

    /// Fires when a background decode installed a texture — a placement
    /// that drew nothing can now draw, so the shell should schedule a
    /// frame. Called on the installing thread; hop to the main queue before
    /// touching view state.
    var onImagesReady: (() -> Void)?

    private let lock = NSLock()
    private var textures: [KittyGraphics.ImageID: MTLTexture] = [:]
    /// Cached texture sizes (`width * height * 4`), kept beside `textures`
    /// so eviction and pruning can account without re-deriving anything.
    private var textureBytes: [KittyGraphics.ImageID: Int] = [:]
    /// Cache order, least-recently-used first — the eviction order when the
    /// per-pane budget needs room.
    private var textureAccessOrder: [KittyGraphics.ImageID] = []
    /// Sum of `textureBytes`, also this renderer's outstanding reservation
    /// against the global budget (released in `deinit`).
    private var textureBytesCached = 0
    /// The `ImagePlacementTable.storeGeneration` each cached texture was
    /// decoded from. A mismatch means the id was re-transmitted and the
    /// cached texture is stale (P05). The synchronous test seam records
    /// generation 0; real transmissions start at 1.
    private var textureGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    /// Images that failed to decode (corrupt PNG, an implausible pixel
    /// count) or to allocate — remembered per store generation so a
    /// permanently-broken transmission does not retry the decode every
    /// frame, while a re-transmission of the same id gets a fresh attempt.
    private var failedGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    /// Images skipped because the *global* texture budget was full —
    /// transient, unlike `failedGenerations`, so they retry once the
    /// budget's generation moves (anything freed by any pane). The budget
    /// generation is recorded per image because the release may come from
    /// another renderer, which this pane cannot observe directly.
    private var budgetBlocked: [KittyGraphics.ImageID: (storeGeneration: UInt64, budgetGeneration: Int)] = [:]
    /// Decodes currently running on `decodeScheduler`, with the store
    /// generation they are decoding. A completion whose generation is no
    /// longer current discards its result — the id was re-transmitted (or
    /// deleted) while the decode ran.
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
        decodeScheduler: ((@escaping () -> Void) -> Void)? = nil,
        // Last so an unlabeled trailing closure binds here, as it did before
        // `decodeImage`/`decodeScheduler` existed.
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

    /// The per-frame entry point, called from `TerminalRenderer.updateInstances`
    /// — *not* from `draw`: nothing here may decode synchronously (P05).
    /// Prunes textures no placement references anymore (including the
    /// empty-table case), invalidates textures whose id was re-transmitted,
    /// and schedules background decodes for placements that are new or newly
    /// visible.
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
        // Bookkeeping for images nothing references anymore can go too; a
        // later re-placement re-decodes from the table, which still holds
        // the bytes until the image itself is deleted.
        failedGenerations = failedGenerations.filter { liveIDs.contains($0.key) }
        budgetBlocked = budgetBlocked.filter { liveIDs.contains($0.key) }
        for id in inFlight.keys where !liveIDs.contains(id) {
            // Orphaned: the completion will find no entry and discard.
            inFlight[id] = nil
        }

        for placement in placements {
            let id = placement.imageID
            guard let data = table.image(id),
                let generation = table.storeGeneration(for: id)
            else { continue }
            if textureGenerations[id] == generation, textures[id] != nil { continue }
            if textureGenerations[id] != generation, textures[id] != nil {
                // Same id, new transmission: the old texture is stale.
                releaseTextureLocked(id)
            }
            guard failedGenerations[id] != generation else { continue }
            if let inFlightGeneration = inFlight[id] {
                if inFlightGeneration == generation { continue }
                // Superseded mid-decode: orphan the old completion and
                // schedule the current bytes instead.
                inFlight[id] = nil
            }
            if let blocked = budgetBlocked[id], blocked.storeGeneration == generation {
                guard blocked.budgetGeneration != globalBudget.generation else { continue }
                // Space was freed somewhere since the skip — retry once.
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

    /// Conservative viewport check for *scheduling* (P05): a placement
    /// provably above or below the viewport is not decoded until it scrolls
    /// into view. A placement whose cell extent cannot be known before
    /// decoding — a PNG transmitted without `c=`/`r=`, whose `s=`/`v=` are
    /// placeholders — answers true, since culling it would mean never
    /// decoding it at all. `draw` re-checks visibility exactly; this check
    /// only avoids paying decodes for offscreen images.
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
        // `totalPushed`, not `.count` (B04) — see `TerminalRenderer.selectionQuads`.
        let viewportRow =
            ScrollbackCoordinates.reanchoredRow(
                placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotalPushed) + offset
        return viewportRow + placementRows > 0 && viewportRow < rows
    }

    /// Runs on `decodeScheduler`: the decode, texture allocation and upload
    /// — everything too expensive for the frame path. Shared with the
    /// synchronous test seam (`texture(for:data:)`), which calls it inline.
    private func decodeAndInstall(
        id: KittyGraphics.ImageID, generation: UInt64, data: KittyGraphics.ImageData
    ) {
        let decoded = decodeImageImpl(data)
        var installed = false
        lock.lock()
        if generation == 0 {
            // The synchronous test seam has no `inFlight` bookkeeping.
            installed = installLocked(id: id, generation: generation, decoded: decoded)
        } else if inFlight[id] == generation {
            inFlight[id] = nil
            installed = installLocked(id: id, generation: generation, decoded: decoded)
        }
        // Otherwise the placement (or this decode's generation of it) went
        // away while decoding — discard the result rather than caching
        // bytes nobody references. Removing `inFlight[id]` is safe only in
        // the matching branch above: a stale completion must not clear the
        // entry of a newer decode scheduled for the same id.
        lock.unlock()
        if installed { onImagesReady?() }
    }

    /// The cache-miss half of `update`'s bookkeeping, shared by the
    /// background completion and the synchronous test seam. Caller holds
    /// `lock`. Returns whether a texture was installed.
    private func installLocked(
        id: KittyGraphics.ImageID, generation: UInt64, decoded: DecodedImage?
    ) -> Bool {
        guard let decoded else {
            failedGenerations[id] = generation
            return false
        }
        let bytes = decoded.width * decoded.height * 4
        // Larger than this pane's whole budget: it can never be cached, so
        // fail it permanently rather than evicting everything every frame.
        guard bytes <= textureByteBudget else {
            failedGenerations[id] = generation
            return false
        }
        while textureBytesCached + bytes > textureByteBudget, let oldest = textureAccessOrder.first {
            releaseTextureLocked(oldest)
        }
        guard globalBudget.tryReserve(bytes) else {
            // Other panes hold the rest of the app-wide budget — transient,
            // so retry once the budget's generation moves instead of failing
            // this id permanently.
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

    /// Drops one cached texture, returning its bytes to both budgets.
    /// Caller holds `lock`.
    private func releaseTextureLocked(_ id: KittyGraphics.ImageID) {
        guard textures.removeValue(forKey: id) != nil, let bytes = textureBytes.removeValue(forKey: id)
        else { return }
        textureGenerations[id] = nil
        textureAccessOrder.removeAll { $0 == id }
        textureBytesCached -= bytes
        globalBudget.release(bytes)
    }

    /// Draws every live placement in `table` that is visible somewhere in
    /// `rect`, in z-index then transmission order — the same layering rule
    /// every reference client documents. `offset`/`scrollbackTotalPushed` place a
    /// placement's document row in the viewport exactly like
    /// `TerminalRenderer.selectionQuads` does for a selection.
    ///
    /// Pure cache reads (P05): a placement whose texture is not cached yet —
    /// decode in flight, culled as offscreen, failed — draws nothing this
    /// frame.
    func draw(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackTotalPushed: Int, rect: CGRect, drawableSize: CGSize,
        quadRenderer: any TerminalRenderBackend, renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        let placements = table.orderedPlacements().sorted { $0.zIndex < $1.zIndex }
        guard !placements.isEmpty else { return }

        for placement in placements {
            guard let texture = texture(for: placement.imageID) else { continue }

            // `totalPushed`, not `.count` (B04) — see `TerminalRenderer.selectionQuads`.
            let viewportRow =
                ScrollbackCoordinates.reanchoredRow(
                    placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotalPushed) + offset
            let columns = placement.columns ?? max(1, Int((Float(texture.width) / cellWidth).rounded(.up)))
            let placementRows =
                placement.rows ?? max(1, Int((Float(texture.height) / cellHeight).rounded(.up)))
            // Entirely above or below the viewport: skip drawing it, same
            // as `selectionQuads` skipping an out-of-view selection.
            guard viewportRow + placementRows > 0, viewportRow < rows else { continue }

            let instance = QuadInstance(
                origin: .init(Float(placement.column) * cellWidth, Float(viewportRow) * cellHeight),
                size: .init(Float(columns) * cellWidth, Float(placementRows) * cellHeight),
                color: .one, uvRect: .init(0, 0, 1, 1))
            quadRenderer.drawColorQuads(
                [instance], atlas: texture, rect: rect, drawableSize: drawableSize,
                renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
            // The glyph/color passes never clear (`TerminalRenderer.draw`'s
            // comment on why) — each placement's draw call has to keep that
            // true for the next one, the same way the glyph pass already
            // does for the pass after it.
            renderPassDescriptor.colorAttachments[0].loadAction = .load
        }
    }

    /// The cached texture for `id`, or nil if it is not (yet) cached. This
    /// is all the frame path is allowed to do (P05): no decode, no
    /// allocation, no scheduling.
    func texture(for id: KittyGraphics.ImageID) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard let texture = textures[id] else { return nil }
        textureAccessOrder.removeAll { $0 == id }
        textureAccessOrder.append(id)
        return texture
    }

    /// Synchronous test seam: runs the whole decode-and-install pipeline
    /// inline, on the caller, for an image with no table behind it
    /// (recorded as generation 0 — real transmissions start at 1, so the
    /// two never collide). The frame path never calls this; `update` is the
    /// production entry point.
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

    /// Premultiplied bgra pixels plus their real dimensions — for PNG,
    /// decoded dimensions can differ from whatever `s=`/`v=` claimed
    /// (typically nothing, since real clients omit them for PNG). Internal,
    /// not private, so tests can build one for the `decodeImage` hook.
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
                    // Premultiplied, matching what `quad_fragment_color`
                    // expects (`Shaders.metal`) — a no-op for opaque RGB
                    // (`a` is always 255 there), real for RGBA.
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
        // Dimensions come off the header *before* `CreateImageAtIndex`
        // decodes anything (S02): a corrupt or hostile stream can declare
        // dimensions whose decode cost dwarfs its byte count, and the caps
        // below are what keep that declared work from ever starting. A
        // header ImageIO cannot parse properties from is rejected here too.
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
        // No CTM flip: `GlyphAtlas.rasterizeColor` explains why a top-down
        // pixel buffer against Core Graphics' y-up drawing space already
        // cancels out — the same reasoning applies to any image drawn into
        // a freshly created bitmap context here.
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
            // Non-empty by construction (`decode` rejects zero dimensions);
            // guarded anyway because a trap here is never justified (S07).
            guard let baseAddress = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, decoded.width, decoded.height), mipmapLevel: 0,
                withBytes: baseAddress, bytesPerRow: decoded.width * 4)
        }
        return texture
    }
}

/// The application-wide half of the image texture budget (S02): decoded
/// image bytes are GPU-resident, VRAM is shared across the whole process,
/// and a per-pane cap alone does not stop N panes from collectively
/// exhausting it. Each `KittyImageRenderer` reserves what it caches and
/// releases on eviction, prune and `deinit`. Lock-guarded because nothing
/// about the type otherwise constrains it to one thread.
nonisolated final class GlobalTextureBudget: @unchecked Sendable {
    static let shared = GlobalTextureBudget(limit: KittyGraphics.maximumGlobalTextureBytes)

    let limit: Int
    private let lock = NSLock()
    private var reserved = 0
    private var releaseCount = 0

    /// Bumped on every release. A renderer that skipped an image while the
    /// budget was full compares this cheaply to learn that space may exist
    /// again — another pane's eviction is otherwise invisible to it, and
    /// re-decoding the skipped image every frame to find out would waste the
    /// decode.
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
