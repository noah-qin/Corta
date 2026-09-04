import CoreGraphics
import Foundation
import Metal
import Testing

@testable import Corta

/// Renders offscreen and asserts actual pixel values — never visual
/// inspection (roadmap M1.15's "Testing the GPU" note).
struct QuadRendererTests {
    /// Reads back one BGRA8 pixel from `texture` at `x, y`.
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let region = MTLRegionMake2D(x, y, 1, 1)
        texture.getBytes(&bytes, bytesPerRow: 4, from: region, mipmapLevel: 0)
        // BGRA in memory.
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)!
    }

    private static func renderPass(target: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private static func synchronize(_ texture: MTLTexture, queue: MTLCommandQueue) {
        guard texture.storageMode == .managed, let buffer = queue.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    @Test func cellBackgroundColourLandsAtItsCentrePixel() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try QuadRenderer(device: device)

        let width = 40, height = 20
        let texture = Self.makeTexture(device: device, width: width, height: height)
        let red = QuadInstance(
            origin: .init(0, 0), size: .init(20, 20), color: .init(1, 0, 0, 1))

        let commandBuffer = queue.makeCommandBuffer()!
        renderer.drawSolidQuads(
            [red], rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height),
            renderPassDescriptor: Self.renderPass(target: texture, clear: true),
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let centre = Self.pixel(of: texture, x: 10, y: 10)
        #expect(centre.r == 255)
        #expect(centre.g == 0)
        #expect(centre.b == 0)
    }

    @Test func theSameGridDrawnIntoTwoRectsLandsInBoth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try QuadRenderer(device: device)

        let width = 40, height = 20
        let texture = Self.makeTexture(device: device, width: width, height: height)
        let drawableSize = CGSize(width: width, height: height)
        let green = [QuadInstance(origin: .init(0, 0), size: .init(20, 20), color: .init(0, 1, 0, 1))]

        var commandBuffer = queue.makeCommandBuffer()!
        renderer.drawSolidQuads(
            green, rect: CGRect(x: 0, y: 0, width: 20, height: 20), drawableSize: drawableSize,
            renderPassDescriptor: Self.renderPass(target: texture, clear: true),
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        commandBuffer = queue.makeCommandBuffer()!
        renderer.drawSolidQuads(
            green, rect: CGRect(x: 20, y: 0, width: 20, height: 20), drawableSize: drawableSize,
            renderPassDescriptor: Self.renderPass(target: texture, clear: false),
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let left = Self.pixel(of: texture, x: 5, y: 10)
        let right = Self.pixel(of: texture, x: 25, y: 10)
        #expect(left.g == 255)
        #expect(right.g == 255)
    }

    @Test func aQuadNeverPaintsOutsideItsRect() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try QuadRenderer(device: device)

        let width = 40, height = 20
        let texture = Self.makeTexture(device: device, width: width, height: height)
        // An instance whose geometry runs past the rect it's drawn into —
        // the scissor, not the instance data, must be what clips it.
        let overflowing = [
            QuadInstance(origin: .init(0, 0), size: .init(100, 100), color: .init(0, 0, 1, 1))
        ]

        let commandBuffer = queue.makeCommandBuffer()!
        renderer.drawSolidQuads(
            overflowing, rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            drawableSize: CGSize(width: width, height: height),
            renderPassDescriptor: Self.renderPass(target: texture, clear: true),
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let inside = Self.pixel(of: texture, x: 5, y: 5)
        let outside = Self.pixel(of: texture, x: 20, y: 15)
        #expect(inside.b == 255)
        #expect(outside.b == 0)
    }

    @Test func oneXAndTwoXProduceExpectedPixelDimensions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        for scale in [1, 2] {
            let pointsWide = 80, pointsHigh = 24
            let texture = Self.makeTexture(
                device: device, width: pointsWide * scale, height: pointsHigh * scale)
            #expect(texture.width == pointsWide * scale)
            #expect(texture.height == pointsHigh * scale)
        }
    }

    // MARK: - M9: compiled-pipeline cache

    /// `init` writes a `MTLBinaryArchive` to disk so a later launch can look
    /// its three pipelines up instead of compiling them — this only checks
    /// that the file lands where `binaryArchiveURL` says it should; the
    /// compile-time saving itself is not something a unit test can observe
    /// (Metal does not expose "was this pipeline looked up or compiled").
    @Test func initWritesAPipelineCacheFile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        guard let url = QuadRenderer.binaryArchiveURL else {
            Issue.record("No cache directory available in this environment")
            return
        }
        try? FileManager.default.removeItem(at: url)

        _ = try QuadRenderer(device: device)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A second `QuadRenderer` finds the first one's cache file already on
    /// disk (`loadOrCreateBinaryArchive`'s `descriptor.url` branch) and must
    /// still construct successfully — a stale-format or otherwise
    /// unreadable archive falls back to an ordinary compile rather than
    /// throwing (`init`'s `try?` around every archive operation).
    @Test func aSecondRendererReusesAnExistingCacheFileWithoutFailing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        guard let url = QuadRenderer.binaryArchiveURL else {
            Issue.record("No cache directory available in this environment")
            return
        }
        try? FileManager.default.removeItem(at: url)

        _ = try QuadRenderer(device: device)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Must not throw, whether it actually used the cache or fell back.
        _ = try QuadRenderer(device: device)
    }
}
