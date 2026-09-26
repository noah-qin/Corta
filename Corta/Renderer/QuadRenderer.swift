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
/// every glyph — which is what "one draw call per screen" (`CONFORMANCE.md` §2.2)
/// is protecting against: a call per cell or per row, not a call per pipeline.
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

    /// The pipelines and sampler come from `QuadPipelineCache`: one
    /// compile per device per process, shared by every pane and by
    /// `Metal4Backend`, instead of each pane re-running the compile/archive
    /// path. The binary-archive warm-up lives in the cache's creation
    /// path — it accelerates the first (cold) creation per
    /// launch; the cache shares that result with panes 2...n, which is the
    /// half the archive never covered.
    init(device: MTLDevice) throws {
        self.device = device
        let entry = try QuadPipelineCache.entry(for: device)
        self.solidPipeline = entry.solidPipeline
        self.glyphPipeline = entry.glyphPipeline
        self.colorGlyphPipeline = entry.colorGlyphPipeline
        self.sampler = entry.sampler
    }

    /// Where a compiled-pipeline cache from a previous launch is looked for,
    /// and where this launch's (re)writes it — `AppPaths.cacheDirectory`,
    /// not Application Support: this is disposable, regenerable content the
    /// system is free to purge, never something a user's session depends on.
    /// That directory is per bundle identifier, so the pruning below can
    /// only ever remove *this* build's older archives (D22).
    ///
    /// Named with `buildFingerprint` — **not** a fixed filename — so a
    /// rebuild's cache is never confused with an older build's: this is a
    /// belt-and-braces measure alongside `isRunningUnderXCTest` below, not
    /// the fix for what that guards (see its doc comment for the actual
    /// crash this file's history is about).
    ///
    /// One file for all three pipelines; keyed by nothing beyond its path.
    /// Not `private`: `QuadRendererTests` checks the file this writes.
    static var binaryArchiveURL: URL? {
        guard let directory = AppPaths.cacheDirectory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneStaleBinaryArchives(in: directory)
        return directory.appendingPathComponent("QuadRenderer-\(buildFingerprint).metallib-archive")
    }

    /// The running executable's modification time, as a filename-safe
    /// integer — changes on every rebuild (a fresh compile writes a new
    /// binary), which is exactly the granularity a Metal-compiled-shader
    /// cache needs to invalidate at. `"unknown"` only if the executable's
    /// own attributes cannot be read, which never happens for a running
    /// process's own binary in practice; a shared, stable "unknown" still
    /// behaves correctly (one cache file, reused within that condition)
    /// rather than crashing or refusing to cache at all.
    private static var buildFingerprint: String {
        guard let url = Bundle.main.executableURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date
        else { return "unknown" }
        return String(Int(modified.timeIntervalSince1970))
    }

    /// Removes every `QuadRenderer-*.metallib-archive` in `directory` that
    /// is not this build's own — otherwise each rebuild during development
    /// leaves the last one behind forever, unbounded, since nothing else
    /// ever revisits this directory. Best-effort: a failed removal here is
    /// not worth surfacing, the file just sits unused.
    private static func pruneStaleBinaryArchives(in directory: URL) {
        let current = "QuadRenderer-\(buildFingerprint).metallib-archive"
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("QuadRenderer-")
            && entry.lastPathComponent != current
        {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Writes `archive` to `url` without ever exposing a partially-written
    /// file at that path: serializes to a uniquely-named temp file in the
    /// same directory first, then atomically replaces `url` with it
    /// (`FileManager.replaceItemAt`, a single `rename(2)` on the same
    /// volume) — so a reader can never open a half-written file, only the
    /// old complete one or the new complete one. Not `private`: called from
    /// `QuadPipelineCache.makeEntry`, where the archive path now lives.
    static func serialize(_ archive: any MTLBinaryArchive, to url: URL) {
        let temporaryURL =
            url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).tmp")
        guard (try? archive.serialize(to: temporaryURL)) != nil else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// `true` while running as (or hosted inside) an XCTest bundle —
    /// `XCTestConfigurationFilePath` is the standard, Apple-set environment
    /// variable for this, present whether the test is unit (`CortaTests`,
    /// which `TEST_HOST`s directly into `Corta` — this process *is* the
    /// test) or UI-driven.
    ///
    /// Exists for exactly one reason: `loadOrCreateBinaryArchive` reading a
    /// previous archive back segfaulted — `-[_MTLDevice
    /// recordBinaryArchiveUsage:]`, a null C-string reaching `strlen`,
    /// inside Metal's own framework code — reproducibly under `CortaTests`.
    /// A standalone command-line reproduction of the identical write-then-
    /// load round trip (same archive, same device, no app, no test
    /// infrastructure) did **not** crash, and neither did two real,
    /// consecutive, bare `Corta.app` launches sharing a cache file (the
    /// scenario this feature exists for) — which points at the *hosted
    /// test* launch path specifically, not the load itself: `CortaTests`
    /// runs injected into `Corta` via `TEST_HOST`, a fundamentally
    /// different launch mechanism from opening the app, and a filed
    /// upstream report of the same crash signature attributes it to
    /// `MTLGetShaderCachePath()` returning nil when something denies
    /// Metal's own internal shader-cache directory — plausible for
    /// whatever container Xcode's hosted-test launch applies that a plain
    /// launch does not.
    ///
    /// Disabling the read path unconditionally would trade away a real,
    /// working optimisation for real users to silence a test-harness-only
    /// crash; this only disables it under that harness.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Opens the cached archive from a previous launch if one exists at
    /// `binaryArchiveURL` — unless `isRunningUnderXCTest`, in which case a
    /// fresh, empty archive is created instead and the file is never read
    /// (its doc comment has the full account of why). Either way, the caller
    /// (`QuadPipelineCache.makeEntry`, the one place the archive path runs
    /// now) adds this launch's three pipeline descriptors to it and
    /// re-serialises it, so a first-ever launch — or every hosted-test
    /// launch — seeds or refreshes the cache a later real launch benefits
    /// from. `nil` on any failure (no archive support, no writable cache
    /// directory): callers fall back to an ordinary synchronous compile,
    /// unconditionally correct either way.
    static func loadOrCreateBinaryArchive(device: MTLDevice) -> (any MTLBinaryArchive)? {
        let descriptor = MTLBinaryArchiveDescriptor()
        if !isRunningUnderXCTest, let url = binaryArchiveURL,
            FileManager.default.fileExists(atPath: url.path)
        {
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
            commandBuffer: commandBuffer, label: "Corta.solid")
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
            commandBuffer: commandBuffer, label: "Corta.glyph")
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
            commandBuffer: commandBuffer, label: "Corta.colorGlyph")
    }

    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        label: String
    ) {
        // Even with zero instances, a `.clear` pass still has to run: the
        // load action must happen so a frame that draws nothing (an all-
        // default-colour blank grid) doesn't leave the previous frame on
        // screen. A `.load` pass with zero instances is the opposite case —
        // it draws nothing and preserves nothing — so skipping it outright
        // is pixel-identical and saves the tile load/store round trip an
        // empty render pass still costs (without it, the glyph pass on a
        // blank screen pays one every frame).
        if instances.isEmpty,
            renderPassDescriptor.colorAttachments[0].loadAction == .load
        {
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }
        // Correlates an Instruments/Metal System Trace capture with which of
        // the up-to-three passes a frame took; purely a label, changes nothing about what draws.
        encoder.label = label
        encoder.pushDebugGroup(label)
        defer {
            encoder.popDebugGroup()
            encoder.endEncoding()
        }
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
