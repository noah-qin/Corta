import CoreGraphics
import Foundation
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
/// a typical frame — one instanced pass for every cell's background, one for
/// every glyph — which is what "one draw call per screen" in the roadmap is
/// protecting against: a call per cell or per row, not a call per pipeline.
/// A frame with color emoji adds a third (the color-atlas pass), skipped
/// entirely when no cell produced a color glyph.
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
    /// The color-atlas variant of the glyph pipeline: its fragment returns
    /// the texture sample (premultiplied bgra) directly instead of tinting
    /// coverage, so it blends premultiplied-over rather than re-multiplying
    /// the source rgb by alpha.
    private let colorGlyphPipeline: MTLRenderPipelineState
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
    private let colorGlyphBufferRing = InstanceBufferRing()

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
            let glyphFragment = library.makeFunction(name: "quad_fragment_glyph"),
            let colorGlyphFragment = library.makeFunction(name: "quad_fragment_color")
        else {
            throw QuadRendererError.functionUnavailable
        }

        // M9: load a cached `MTLBinaryArchive` if one exists from a
        // previous launch, so these three pipelines are looked up instead of
        // compiled — the cold-start cost this exists to remove is entirely
        // on first window paint, first glyph, first emoji and a font switch,
        // never inside a frame. `nil` (no archive support on this device, no
        // write access to the cache directory, first launch ever) falls
        // straight through to the ordinary synchronous compile below; this
        // is a startup-latency optimisation; it does not change what gets
        // drawn if it is unavailable.
        let archive = QuadRenderer.loadOrCreateBinaryArchive(device: device)

        func makePipeline(fragment: MTLFunction, premultipliedSource: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = QuadRenderer.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            // `.one` for a premultiplied source (the color atlas): the
            // sample's rgb is already alpha-scaled, so multiplying by
            // sourceAlpha again would double-darken every translucent texel.
            attachment.sourceRGBBlendFactor = premultipliedSource ? .one : .sourceAlpha
            // `.one`, not `.sourceAlpha`: the drawable is composited by Core
            // Animation as premultiplied alpha, so the alpha channel must
            // accumulate as src.a + dst.a*(1-src.a). Squaring it here made
            // every translucent pixel report less coverage than it has.
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            if let archive {
                descriptor.binaryArchives = [archive]
                // Duplicates across launches are silently accepted (Metal's
                // own doc comment on this method) — this both seeds a
                // first-ever-launch archive and keeps a stale one current,
                // with no need to first check whether today's descriptor is
                // already in it.
                try? archive.addRenderPipelineFunctions(descriptor: descriptor)
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.solidPipeline = try makePipeline(fragment: solidFragment)
        self.glyphPipeline = try makePipeline(fragment: glyphFragment)
        self.colorGlyphPipeline = try makePipeline(fragment: colorGlyphFragment, premultipliedSource: true)
        if let archive, let url = QuadRenderer.binaryArchiveURL {
            try? archive.serialize(to: url)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadRendererError.samplerUnavailable
        }
        self.sampler = sampler
    }

    /// Where a compiled-pipeline cache from a previous launch is looked for,
    /// and where this launch's (re)writes it — `~/Library/Caches`, not
    /// Application Support: this is disposable, regenerable content the
    /// system is free to purge, never something a user's session depends on.
    /// One file for all three pipelines; keyed by nothing beyond its path,
    /// since a stale entry (an OS or driver update, per `MTLBinaryArchive`'s
    /// own doc comment) just falls through to an ordinary compile, the same
    /// as no file at all.
    /// Not `private`: `QuadRendererTests` checks the file this writes.
    static var binaryArchiveURL: URL? {
        guard
            let cachesDirectory = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = cachesDirectory.appendingPathComponent("dev.noahqin.Corta", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("QuadRenderer.metallib-archive")
    }

    /// Opens the cached archive from a previous launch if one exists at
    /// `binaryArchiveURL`, or creates an empty one to populate this launch —
    /// either way, `init` above adds this launch's three pipeline
    /// descriptors to it and re-serialises it, so a first-ever launch seeds
    /// the cache the next one benefits from. `nil` on any failure (no
    /// archive support, no writable cache directory): callers fall back to
    /// an ordinary synchronous compile, unconditionally correct either way.
    private static func loadOrCreateBinaryArchive(device: MTLDevice) -> (any MTLBinaryArchive)? {
        let descriptor = MTLBinaryArchiveDescriptor()
        if let url = binaryArchiveURL, FileManager.default.fileExists(atPath: url.path) {
            descriptor.url = url
        }
        return try? device.makeBinaryArchive(descriptor: descriptor)
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

    /// Draws `instances` sampled from the *color* atlas into `rect`. Same
    /// quad math as `drawGlyphQuads`; the difference is entirely in the
    /// fragment (sample verbatim, no tint) and the blend (premultiplied
    /// source) — see `colorGlyphPipeline`.
    func drawColorQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        draw(
            instances, ring: colorGlyphBufferRing, pipeline: colorGlyphPipeline, atlas: atlas,
            rect: rect, drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
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
