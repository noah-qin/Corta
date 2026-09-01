import CoreGraphics
import CoreText
import Metal
import Testing

@testable import Corta

struct GlyphAtlasTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }

    @Test func asciiPathNeverCallsIntoShaping() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let atlas = GlyphAtlas(device: device, font: font)

        for scalar in UInt32(0x21)...UInt32(0x7E) {
            _ = atlas.glyph(forASCII: scalar, bold: false)
        }

        #expect(atlas.fastPathHits > 0)
        #expect(atlas.shapingHits == 0)
    }

    @Test func nonASCIIGoesThroughTheShapingCacheAndIsCachedAfterOnce() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let atlas = GlyphAtlas(device: device, font: font)

        _ = atlas.glyph(shaping: 0x4E2D, bold: false)  // 中
        #expect(atlas.shapingHits == 1)
        _ = atlas.glyph(shaping: 0x4E2D, bold: false)
        #expect(atlas.shapingHits == 1)  // second lookup is a cache hit
    }

    @Test func aGlyphProducesInkInsideItsCellAndNoneOutside() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try QuadRenderer(device: device)
        let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
        let atlas = GlyphAtlas(device: device, font: font)

        guard let info = atlas.glyph(forASCII: UInt32(Character("X").asciiValue!), bold: true),
            info.size != .zero
        else {
            Issue.record("'X' rasterised to an empty glyph")
            return
        }

        let cellWidth: Float = 40, cellHeight: Float = 40
        let instance = QuadInstance(
            origin: .init(info.bearing.x, cellHeight - info.bearing.y - info.size.y),
            size: info.size, color: .init(1, 1, 1, 1), uvRect: info.uvRect)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: Int(cellWidth), height: Int(cellHeight),
            mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        let target = device.makeTexture(descriptor: targetDescriptor)!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        let commandBuffer = queue.makeCommandBuffer()!
        renderer.drawGlyphQuads(
            [instance], atlas: atlas.texture,
            rect: CGRect(x: 0, y: 0, width: Double(cellWidth), height: Double(cellHeight)),
            drawableSize: CGSize(width: Double(cellWidth), height: Double(cellHeight)),
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if target.storageMode == .managed, let blitBuffer = queue.makeCommandBuffer(),
            let blit = blitBuffer.makeBlitCommandEncoder()
        {
            blit.synchronize(resource: target)
            blit.endEncoding()
            blitBuffer.commit()
            blitBuffer.waitUntilCompleted()
        }

        // Sample the centre of the glyph's own quad, not the cell's — a
        // narrow or off-centre glyph like 'X' at this size does not
        // necessarily reach the middle of an oversized cell.
        let sampleX = Int((instance.origin.x + instance.size.x / 2).rounded())
        let sampleY = Int((instance.origin.y + instance.size.y / 2).rounded())
        let centre = Self.pixel(of: target, x: sampleX, y: sampleY)
        let corner = Self.pixel(of: target, x: 1, y: 1)
        #expect(centre.r > 0, "expected ink at the centre of a rasterised 'X'")
        #expect(corner.r == 0, "expected background outside the glyph's ink")
    }
}
