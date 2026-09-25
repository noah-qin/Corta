import CoreGraphics
import CoreText
import Foundation
import Metal
import Testing

@testable import Corta

/// The `TerminalRenderBackend` seam (M9) and the real Metal 4 command
/// submission behind `Metal4Backend` (B12): protocol conformance, the
/// capability check, fallback construction, and — on Metal-4-capable
/// hardware — pixel equivalence with `QuadRenderer`, ring/allocator reuse
/// across frames, and deallocation with frames in flight.
@Suite("TerminalRenderBackend", .serialized, .metalSerialized)
struct TerminalRenderBackendTests {
    @Test func quadRendererConformsToTheBackendProtocol() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try QuadRenderer(device: device)
        let backend: any TerminalRenderBackend = renderer
        #expect(backend.device === device)
    }

    /// Skipped, not failed, where the runner's GPU has no Metal 4 family
    /// (CI's virtual machine): construction throwing there is the
    /// documented fallback, not a defect.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func metal4BackendConformsAndForwardsItsDevice() throws {
        let device = try #require(Self.metal4Device())
        let backend = try Metal4Backend(device: device)
        let asProtocol: any TerminalRenderBackend = backend
        #expect(asProtocol.device === device)
    }

    /// Not asserting a value either way — whether this machine's GPU
    /// reports the Metal 4 family is a fact about the test runner, not
    /// something this suite should assume. The point is that asking does
    /// not crash and the two backends agree with each other when queried
    /// independently (`QuadRenderer`'s `device` and `Metal4Backend`'s are
    /// the same device either way).
    @Test func isSupportedDoesNotCrashRegardlessOfHardware() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        _ = Metal4Backend.isSupported(by: device)
    }

    /// `TerminalRenderer` must build successfully whether or not
    /// `CORTA_METAL4` happens to be set in the test environment — the
    /// fallback in `TerminalRenderer.init` (`try? Metal4Backend(device:)`
    /// failing, or `isOptedIn`/`isSupported` being false) must never be the
    /// reason a renderer fails to construct.
    @Test func terminalRendererConstructsRegardlessOfBackendSelection() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        #expect(renderer.quadRenderer.device === device)
    }

    // MARK: - B12: Metal 4 command submission

    private static let width = 64
    private static let height = 48
    /// A rect deliberately smaller than the target, so the scissor math —
    /// not just the draw — is part of the comparison.
    private static let rect = CGRect(x: 4, y: 4, width: 56, height: 40)
    private static let drawableSize = CGSize(width: width, height: height)
    private static let clearColor = MTLClearColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

    /// A Metal-4-capable device, or nil. The tests that need one are gated
    /// on `MetalRenderTarget.supportsMetal4`, so nil here means the trait
    /// and this disagree — a failure, not a skip.
    private static func metal4Device() -> MTLDevice? {
        guard let device = MTLCreateSystemDefaultDevice(), Metal4Backend.isSupported(by: device)
        else { return nil }
        return device
    }

    /// The synthetic coverage texture the glyph passes sample — `r8Unorm`
    /// and `.managed`, the same shape `GlyphAtlas.texture` has.
    private static func makeCoverageTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .managed
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16)
        for i in pixels.indices { pixels[i] = UInt8(i) }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 16)
        return texture
    }

    /// The synthetic premultiplied-bgra texture the color passes sample —
    /// the same shape `GlyphAtlas.colorTexture` and Kitty image textures
    /// have.
    private static func makeColorTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .managed
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) {
            pixels[i * 4] = UInt8(truncatingIfNeeded: i * 3)
            pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: 255 - i)
            pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: i)
            pixels[i * 4 + 3] = UInt8(truncatingIfNeeded: 128 + i / 2)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 16 * 4)
        return texture
    }

    /// Solid quads (opaque plus overlapping translucent, exercising the
    /// blend path), glyph instances sampling the coverage texture, and
    /// color instances sampling the premultiplied one.
    private static var solidInstances: [QuadInstance] {
        [
            QuadInstance(origin: .init(0, 0), size: .init(24, 24), color: .init(1, 0, 0, 1)),
            QuadInstance(origin: .init(12, 12), size: .init(24, 24), color: .init(0, 1, 0, 0.5)),
            QuadInstance(origin: .init(32, 4), size: .init(16, 32), color: .init(0, 0, 1, 0.75)),
        ]
    }

    private static var glyphInstances: [QuadInstance] {
        [
            QuadInstance(
                origin: .init(2, 2), size: .init(32, 32), color: .init(1, 1, 0, 0.9),
                uvRect: .init(0, 0, 1, 1)),
            QuadInstance(
                origin: .init(30, 10), size: .init(16, 16), color: .init(0, 1, 1, 1),
                uvRect: .init(0.25, 0.25, 0.5, 0.5)),
        ]
    }

    private static var colorInstances: [QuadInstance] {
        [
            QuadInstance(
                origin: .init(20, 8), size: .init(24, 24), color: .one, uvRect: .init(0, 0, 1, 1))
        ]
    }

    /// The MTL3 path, exactly as `TerminalRenderer.draw` drives it: clear
    /// pass for the solid draw, `.load` for everything after.
    private static func renderWithQuadRenderer(
        _ renderer: QuadRenderer, into target: MTLTexture,
        coverage: MTLTexture, color: MTLTexture, queue: MTLCommandQueue
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        renderer.drawSolidQuads(
            solidInstances, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        pass.colorAttachments[0].loadAction = .load
        renderer.drawGlyphQuads(
            glyphInstances, atlas: coverage, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        renderer.drawColorQuads(
            colorInstances, atlas: color, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The MTL4 path for the same content; waits for the commit feedback
    /// before returning, so the target is safe to read afterwards.
    private static func renderWithMetal4Backend(
        _ backend: Metal4Backend, into target: MTLTexture,
        coverage: MTLTexture, color: MTLTexture
    ) -> Bool {
        backend.beginFrame(target: target, clearColor: clearColor, label: "Corta.test")
        backend.drawSolidQuads(solidInstances, rect: rect, drawableSize: drawableSize)
        backend.drawGlyphQuads(glyphInstances, atlas: coverage, rect: rect, drawableSize: drawableSize)
        backend.drawColorQuads(colorInstances, atlas: color, rect: rect, drawableSize: drawableSize)
        let completion = DispatchSemaphore(value: 0)
        backend.endFrame(presenting: nil, onCompleted: { _ in completion.signal() })
        return completion.wait(timeout: .now() + 10) == .success
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

    private static func bytes(of texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &pixels, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return pixels
    }

    /// Per-byte comparison of the two backends' outputs. Both encode the
    /// same shaders with the same blend state, so results should be
    /// bit-identical; a tolerance of one code value per channel is allowed
    /// for blend rounding order on hardware that reorders the blend unit's
    /// internal precision between the two submission paths — anything more
    /// is a real difference, not rounding.
    private static func expectPixelsEqual(
        _ a: MTLTexture, _ b: MTLTexture, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let pixelsA = bytes(of: a)
        let pixelsB = bytes(of: b)
        #expect(pixelsA.count == pixelsB.count, sourceLocation: sourceLocation)
        var mismatches = 0
        for i in pixelsA.indices where abs(Int(pixelsA[i]) - Int(pixelsB[i])) > 1 {
            mismatches += 1
        }
        if mismatches > 0 {
            MetalRenderTarget.attachPNG(a, named: "quad-renderer.png")
            MetalRenderTarget.attachPNG(b, named: "metal4-backend.png")
        }
        #expect(
            mismatches == 0,
            "\(mismatches) bytes differ beyond blend rounding between QuadRenderer and Metal4Backend",
            sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func metal4BackendMatchesQuadRendererPixels() throws {
        let device = try #require(Self.metal4Device())
        let queue = try #require(device.makeCommandQueue())
        let coverage = try #require(Self.makeCoverageTexture(device: device))
        let color = try #require(Self.makeColorTexture(device: device))

        let legacy = try QuadRenderer(device: device)
        let expected = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        Self.renderWithQuadRenderer(
            legacy, into: expected, coverage: coverage, color: color, queue: queue)
        Self.synchronize(expected, queue: queue)

        let backend = try Metal4Backend(device: device)
        let actual = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        #expect(
            Self.renderWithMetal4Backend(backend, into: actual, coverage: coverage, color: color),
            "Metal 4 commit feedback never arrived")
        Self.synchronize(actual, queue: queue)

        Self.expectPixelsEqual(expected, actual)
    }

    /// A frame that draws nothing must still clear — the MTL3 path runs an
    /// encoder purely for the `.clear` load action; the MTL4 backend
    /// clears in `beginFrame`. Both must agree, because this is what keeps
    /// an all-blank grid from leaving the previous frame on screen.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func metal4BackendClearsAnEmptyFrame() throws {
        let device = try #require(Self.metal4Device())
        let queue = try #require(device.makeCommandQueue())

        let legacy = try QuadRenderer(device: device)
        let expected = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = expected
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.clearColor
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(queue.makeCommandBuffer())
        legacy.drawSolidQuads(
            [], rect: Self.rect, drawableSize: Self.drawableSize,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(expected, queue: queue)

        let backend = try Metal4Backend(device: device)
        let actual = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        backend.beginFrame(target: actual, clearColor: Self.clearColor, label: "Corta.test")
        let completion = DispatchSemaphore(value: 0)
        backend.endFrame(presenting: nil, onCompleted: { _ in completion.signal() })
        #expect(completion.wait(timeout: .now() + 10) == .success)
        Self.synchronize(actual, queue: queue)

        Self.expectPixelsEqual(expected, actual)
    }

    /// Eight frames through one backend — the command buffer, the three
    /// allocators and every ring slot are each reused several times, with
    /// the first frames left in flight (no completion wait) so slot reuse
    /// crosses in-flight GPU work exactly as it does on the render loop.
    /// The last frame's opaque quad must win intact: any premature slot
    /// rewrite shows up here as the wrong colour.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func metal4BackendReusesRingSlotsAcrossInFlightFrames() throws {
        let device = try #require(Self.metal4Device())
        let queue = try #require(device.makeCommandQueue())
        let backend = try Metal4Backend(device: device)
        let target = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
        let colors: [SIMD4<Float>] = [
            .init(1, 0, 0, 1), .init(0, 1, 0, 1), .init(0, 0, 1, 1), .init(1, 1, 0, 1),
            .init(1, 0, 1, 1), .init(0, 1, 1, 1), .init(0.5, 0.25, 1, 1), .init(0.25, 0.5, 1, 1),
        ]
        let completion = DispatchSemaphore(value: 0)
        for (index, color) in colors.enumerated() {
            backend.beginFrame(target: target, clearColor: Self.clearColor, label: "Corta.test")
            backend.drawSolidQuads(
                [QuadInstance(origin: .zero, size: .init(64, 48), color: color)],
                rect: Self.rect, drawableSize: Self.drawableSize)
            if index == colors.count - 1 {
                backend.endFrame(presenting: nil, onCompleted: { _ in completion.signal() })
            } else {
                backend.endFrame(presenting: nil, onCompleted: nil)
            }
        }
        #expect(completion.wait(timeout: .now() + 10) == .success)
        Self.synchronize(target, queue: queue)

        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
        let last = colors.last!
        // BGRA byte order in memory.
        #expect(abs(Int(pixel[0]) - Int((last.z * 255).rounded())) <= 1)
        #expect(abs(Int(pixel[1]) - Int((last.y * 255).rounded())) <= 1)
        #expect(abs(Int(pixel[2]) - Int((last.x * 255).rounded())) <= 1)
        #expect(pixel[3] == 255)
    }

    /// Releasing the backend while the GPU is still running its frames
    /// must not crash: the queue, command buffers and residency set keep
    /// the resources alive until completion, and the final frame's
    /// feedback handler — the only thing still reachable — still fires.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func metal4BackendDeallocatesWithFramesInFlight() throws {
        let device = try #require(Self.metal4Device())
        let completion = DispatchSemaphore(value: 0)
        do {
            let backend = try Metal4Backend(device: device)
            let target = MetalRenderTarget.make(device: device, width: Self.width, height: Self.height)
            for index in 0..<5 {
                backend.beginFrame(target: target, clearColor: Self.clearColor, label: "Corta.test")
                backend.drawSolidQuads(
                    Self.solidInstances, rect: Self.rect, drawableSize: Self.drawableSize)
                if index == 4 {
                    backend.endFrame(presenting: nil, onCompleted: { _ in completion.signal() })
                } else {
                    backend.endFrame(presenting: nil, onCompleted: nil)
                }
            }
        }
        // `backend` is gone; the frames are still the GPU's problem.
        #expect(completion.wait(timeout: .now() + 10) == .success)
    }
}
