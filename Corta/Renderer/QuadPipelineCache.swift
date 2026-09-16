import Foundation
import Metal

/// B12 (issue #39): the per-device shared half of cross-pane resource
/// sharing. Until this existed, every pane compiled its own copy of the
/// same three render pipeline states (plus one sampler) — identical
/// descriptors, same device, same shader library — because each pane builds
/// its own `QuadRenderer` (`ViewController.setUpPane` → `TerminalRenderer`
/// → backend). The MTLBinaryArchive (M9) makes the *first* compile per
/// launch cheap; it never made panes 2...n cheap, each of which re-ran the
/// whole lookup/compile/serialise path. This cache holds the result
/// in-process: one compile per device per process, every later pane a
/// dictionary lookup.
///
/// Sharing is safe here for exactly one reason: everything in `Entry` is
/// immutable after creation. `MTLRenderPipelineState` and `MTLSamplerState`
/// are value-like GPU objects — encoders bind them, nothing mutates them —
/// which is what distinguishes this from `GlyphAtlas`, whose mutability is
/// why atlases stay per-pane (see the evaluation comment at the atlas's
/// creation site in `TerminalRenderer.init`).
///
/// Keyed by device identity alone. The task list's "+ shader library
/// identity" collapses into the device key: the library here is
/// `makeDefaultLibrary()`, compiled from the process binary's embedded
/// metallib, fixed for the life of the process (cross-build changes are
/// what the archive's `buildFingerprint` filename is for). Keying on
/// `ObjectIdentifier(library)` as well would only add the risk of never
/// hitting, since Metal is not documented to vend the same library object
/// for repeated calls.
///
/// Thread safety: `lock` serialises both the lookup and the one-time
/// creation. Creation includes the binary-archive load/compile/serialise
/// path, so this is the only lock the archive bookkeeping needs — it never
/// happens outside entry creation, and entry creation happens at most once
/// per device per process. Panes are created on the main thread today regardless; the lock
/// is the cheap guarantee, not a response to an observed race.
nonisolated enum QuadPipelineCache {
    /// The immutable bundle both backends draw with. A class so the cache's
    /// clients share one instance; `let`-only, so sharing needs no
    /// synchronisation beyond the cache's own lock at hand-out time.
    nonisolated final class Entry {
        /// Retained so the `ObjectIdentifier` cache key can never be
        /// recycled by a deallocated device while its entry lives.
        let device: MTLDevice
        let solidPipeline: MTLRenderPipelineState
        let glyphPipeline: MTLRenderPipelineState
        /// The color-atlas variant of the glyph pipeline — premultiplied
        /// source blending; see `QuadRenderer`'s doc comments for the blend
        /// rationale the two backends share.
        let colorGlyphPipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState

        init(
            device: MTLDevice, solidPipeline: MTLRenderPipelineState,
            glyphPipeline: MTLRenderPipelineState,
            colorGlyphPipeline: MTLRenderPipelineState, sampler: MTLSamplerState
        ) {
            self.device = device
            self.solidPipeline = solidPipeline
            self.glyphPipeline = glyphPipeline
            self.colorGlyphPipeline = colorGlyphPipeline
            self.sampler = sampler
        }
    }

    private static let lock = NSLock()
    // Mutated only under `lock`; the checker cannot see that, so it is told
    // explicitly (same pattern as `RenderMetrics.samples`).
    nonisolated(unsafe) private static var entries: [ObjectIdentifier: Entry] = [:]

    /// The shared pipelines and sampler for `device`, creating them on first
    /// ask. Only the creation path touches the shader compiler, the binary
    /// archive and the filesystem; a hit is a locked dictionary lookup.
    static func entry(for device: MTLDevice) throws -> Entry {
        let key = ObjectIdentifier(device)
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] { return entry }
        let entry = try makeEntry(device: device)
        entries[key] = entry
        return entry
    }

    /// Test hook: drops every cached entry so a test can observe the cold
    /// (compiling) path after another test has already warmed it — the
    /// archive tests in `QuadRendererTests` need a creation to actually run
    /// to see the archive file rewritten. Never called in the app.
    static func resetForTesting() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Compiles the three pipeline states and creates the sampler — the
    /// exact descriptors `QuadRenderer` has always used, so both backends
    /// produce identical pixels for identical instances (the
    /// pixel-equivalence tests in `TerminalRenderBackendTests` hold that).
    ///
    /// The M9 binary-archive warm-up lives here now: a cold entry creation
    /// looks the pipelines up in a previous launch's archive instead of
    /// compiling them, then re-serialises the archive so this launch's
    /// descriptors seed the next one's. Under XCTest the archive read path
    /// stays disabled — see `QuadRenderer.isRunningUnderXCTest` for the
    /// hosted-test crash that guard exists for — so tests always exercise
    /// the real compile.
    private static func makeEntry(device: MTLDevice) throws -> Entry {
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

        let solidPipeline = try makePipeline(fragment: solidFragment)
        let glyphPipeline = try makePipeline(fragment: glyphFragment)
        let colorGlyphPipeline = try makePipeline(fragment: colorGlyphFragment, premultipliedSource: true)
        if let archive, let url = QuadRenderer.binaryArchiveURL {
            QuadRenderer.serialize(archive, to: url)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadRendererError.samplerUnavailable
        }

        return Entry(
            device: device, solidPipeline: solidPipeline, glyphPipeline: glyphPipeline,
            colorGlyphPipeline: colorGlyphPipeline, sampler: sampler)
    }
}
