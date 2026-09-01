import CoreGraphics
import Metal

enum QuadRendererError: Error {
    case libraryUnavailable
    case functionUnavailable
    case samplerUnavailable
}

/// Draws instanced quads — solid backgrounds, or glyphs sampled from an
/// atlas — into a caller-given rectangle of a caller-given render target.
///
/// Every entry point takes a `CGRect` and a `MTLRenderPassDescriptor`; this
/// type never assumes "the window" (`DESIGN.md` §2.4). Two draw calls cover
/// a full frame — one instanced pass for every cell's background, one for
/// every glyph — which is what "one draw call per screen" in the roadmap is
/// protecting against: a call per cell or per row, not a call per pipeline.
///
/// **Colour space.** Cell colours and the glyph atlas both hold sRGB-encoded
/// values, and blending (glyph alpha over a cell's background) happens
/// directly in that encoded space — the render target is `.bgra8Unorm`, not
/// `.bgra8Unorm_srgb`, so no implicit linearisation happens on read or
/// write. This matches how xterm, Alacritty and Ghostty composite text and
/// is the simpler, faster choice; a fully linear-light blend is deferred
/// until stem darkening is tackled (`DESIGN.md` §7, known hard part 5).
nonisolated final class QuadRenderer {
    let device: MTLDevice
    private let solidPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// A small ring of GPU-visible instance buffers per pipeline kind
    /// (`PERFORMANCE.md` §3: "triple-buffer the Metal instance buffer,
    /// avoids a CPU/GPU stall waiting on the previous frame"). Each call to
    /// `drawSolidQuads`/`drawGlyphQuads` writes into the next slot in its
    /// own ring rather than the last one a command buffer may still be
    /// reading from.
    private final class InstanceBufferRing {
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        private var next = 0

        /// A buffer sized for `byteCount`, with `bytes` already written to
        /// it. Grows a ring slot (never shrinks) rather than allocating a
        /// fresh buffer whenever the previous one is already big enough —
        /// the steady state for an unchanging window size is zero
        /// allocation per frame (`PERFORMANCE.md` §3).
        func buffer(bytes: UnsafeRawPointer, byteCount: Int, device: MTLDevice) -> MTLBuffer? {
            guard byteCount > 0 else { return nil }
            let slot = next
            next = (next + 1) % buffers.count
            if let existing = buffers[slot], existing.length >= byteCount {
                existing.contents().copyMemory(from: bytes, byteCount: byteCount)
                return existing
            }
            guard let fresh = device.makeBuffer(bytes: bytes, length: byteCount, options: .storageModeShared)
            else { return nil }
            buffers[slot] = fresh
            return fresh
        }
    }

    private let solidBufferRing = InstanceBufferRing()
    private let glyphBufferRing = InstanceBufferRing()

    /// The pixel format every render target passed to this renderer must
    /// use — the pipelines are built against it up front.
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init(device: MTLDevice) throws {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw QuadRendererError.libraryUnavailable
        }
        guard let vertexFunction = library.makeFunction(name: "quad_vertex"),
            let solidFragment = library.makeFunction(name: "quad_fragment_solid"),
            let glyphFragment = library.makeFunction(name: "quad_fragment_glyph")
        else {
            throw QuadRendererError.functionUnavailable
        }

        func makePipeline(fragment: MTLFunction) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = QuadRenderer.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            // `.one`, not `.sourceAlpha`: the drawable is composited by Core
            // Animation as premultiplied alpha, so the alpha channel must
            // accumulate as src.a + dst.a*(1-src.a). Squaring it here made
            // every translucent pixel report less coverage than it has.
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.solidPipeline = try makePipeline(fragment: solidFragment)
        self.glyphPipeline = try makePipeline(fragment: glyphFragment)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadRendererError.samplerUnavailable
        }
        self.sampler = sampler
    }

    /// Draws solid-colour `instances` into `rect` (pixels, relative to the
    /// render target's origin) of `renderPassDescriptor`.
    func drawSolidQuads(
        _ instances: [QuadInstance],
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: solidBufferRing, pipeline: solidPipeline, atlas: nil, rect: rect,
            drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer)
    }

    /// Draws `instances` sampled from `atlas` into `rect`.
    func drawGlyphQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: glyphBufferRing, pipeline: glyphPipeline, atlas: atlas, rect: rect,
            drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer)
    }

    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        // Even with zero instances, the encoder still has to run: a `.clear`
        // load action must happen so a frame that draws nothing (an all-
        // default-colour blank grid) doesn't leave the previous frame on
        // screen.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }
        defer { encoder.endEncoding() }
        guard !instances.isEmpty else { return }

        // Clipping to `rect` via the scissor is what makes "renders into a
        // rect, not the window" true rather than aspirational: nothing an
        // instance does can paint outside it.
        let x = max(0, Int(rect.minX.rounded(.down)))
        let y = max(0, Int(rect.minY.rounded(.down)))
        let maxWidth = max(0, Int(drawableSize.width) - x)
        let maxHeight = max(0, Int(drawableSize.height) - y)
        let width = min(Int(rect.width.rounded(.up)), maxWidth)
        let height = min(Int(rect.height.rounded(.up)), maxHeight)
        guard width > 0, height > 0 else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(drawableSize.width), height: Double(drawableSize.height),
                znear: 0, zfar: 1))

        var uniforms = QuadUniforms(
            rectOrigin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            rectSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        )
        // `setVertexBytes` is documented for small, transient data only —
        // Metal enforces a 4 KB cap, and a full screen of instances (up to
        // ~200×64 cells × 48 bytes) is routinely 20-40x that. A real
        // `MTLBuffer` has no such limit.
        let instanceByteCount = MemoryLayout<QuadInstance>.stride * instances.count
        guard
            let instanceBuffer = instances.withUnsafeBytes({ raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return ring.buffer(bytes: base, byteCount: instanceByteCount, device: device)
            })
        else { return }
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)

        if let atlas {
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }

        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}
