import CoreGraphics
import CortaTerminal
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
/// **Decoding.** RGB/RGBA are already pixels — reordered to premultiplied
/// bgra by hand. PNG is decoded via `CGImageSource` into a premultiplied
/// bgra `CGContext`, the same technique `GlyphAtlas.rasterizeColor` already
/// uses for color emoji, reused here rather than reinvented.
///
/// **Caching.** One texture per image id, decoded once and kept until that
/// id is no longer in `ImagePlacementTable` at all (`pruneUnusedTextures`,
/// called once a frame). A re-transmission that reuses an id already
/// cached is not re-decoded — real clients pick a fresh id per image
/// specifically to avoid this, so it is treated as the rare case it is
/// rather than tracked proactively.
nonisolated final class KittyImageRenderer {
    private let device: MTLDevice
    private var textures: [KittyGraphics.ImageID: MTLTexture] = [:]
    /// Images that failed to decode (corrupt PNG, an implausible pixel
    /// count) — remembered so a placement of a permanently-broken image
    /// does not retry the decode every single frame.
    private var failedIDs: Set<KittyGraphics.ImageID> = []

    init(device: MTLDevice) {
        self.device = device
    }

    /// Draws every live placement in `table` that is visible somewhere in
    /// `rect`, in z-index then transmission order — the same layering rule
    /// every reference client documents. `offset`/`scrollbackCount` place a
    /// placement's document row in the viewport exactly like
    /// `TerminalRenderer.selectionQuads` does for a selection.
    func draw(
        table: ImagePlacementTable, cellWidth: Float, cellHeight: Float, rows: Int,
        offset: Int, scrollbackCount: Int, rect: CGRect, drawableSize: CGSize,
        quadRenderer: any TerminalRenderBackend, renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        let placements = table.orderedPlacements().sorted { $0.zIndex < $1.zIndex }
        guard !placements.isEmpty else { return }
        pruneUnusedTextures(stillReferencedBy: placements)

        for placement in placements {
            guard let imageData = table.image(placement.imageID),
                let texture = texture(for: placement.imageID, data: imageData)
            else { continue }

            let growth = max(0, scrollbackCount - placement.baseScrollbackTotal)
            let viewportRow = placement.row - growth + offset
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

    private func pruneUnusedTextures(stillReferencedBy placements: [KittyGraphics.Placement]) {
        let liveIDs = Set(placements.map(\.imageID))
        for id in textures.keys where !liveIDs.contains(id) {
            textures[id] = nil
        }
        failedIDs.formIntersection(liveIDs)
    }

    private func texture(for id: KittyGraphics.ImageID, data: KittyGraphics.ImageData) -> MTLTexture? {
        if let cached = textures[id] { return cached }
        guard !failedIDs.contains(id) else { return nil }
        guard let decoded = Self.decode(data), let texture = makeTexture(from: decoded) else {
            failedIDs.insert(id)
            return nil
        }
        textures[id] = texture
        return texture
    }

    /// Premultiplied bgra pixels plus their real dimensions — for PNG,
    /// decoded dimensions can differ from whatever `s=`/`v=` claimed
    /// (typically nothing, since real clients omit them for PNG).
    private struct DecodedImage {
        var width: Int
        var height: Int
        var bgra: [UInt8]
    }

    private static func decode(_ data: KittyGraphics.ImageData) -> DecodedImage? {
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
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
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
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        decoded.bgra.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, decoded.width, decoded.height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: decoded.width * 4)
        }
        return texture
    }
}
