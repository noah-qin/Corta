import CoreGraphics
import Foundation
import Metal

enum Metal4BackendError: Error {
    case commandBufferUnavailable
    case commandAllocatorUnavailable
    case sharedEventUnavailable
}

/// A `TerminalRenderBackend` that submits through the Metal 4 command
/// submission API — `MTL4CommandQueue`, `MTL4CommandBuffer`,
/// `MTL4CommandAllocator`, `MTL4RenderCommandEncoder` and argument tables
/// (`MTL4ArgumentTable`) — rather than the `MTLCommandQueue`/
/// `MTLRenderCommandEncoder` path `QuadRenderer` uses (B12, issue #39).
///
/// **What is MTL4 here, and what is not.** Every frame is encoded into an
/// `MTL4CommandBuffer` (a persistent object, re-`begin`n each frame — MTL4
/// command buffers are reusable, unlike `MTL3`'s per-frame ones) through a
/// real `MTL4RenderCommandEncoder`, bound by address through one reused
/// argument table (`setAddress`/`setTexture`/`setSamplerState` — MTL4 has
/// no `setVertexBytes`, so uniforms live in the ring buffers alongside the
/// instances), committed to an `MTL4CommandQueue`, with drawable
/// presentation via `signalDrawable` + `MTLDrawable.present`. The pipeline
/// state objects are the classic `MTLRenderPipelineState`, compiled with
/// `device.makeRenderPipelineState(descriptor:)` — that is not a gap:
/// `MTL4RenderCommandEncoder.setRenderPipelineState` takes exactly that
/// type, and MTL4's own compiler (`MTL4Compiler.newRenderPipelineState`)
/// returns it too. `MTL4Compiler`/`MTL4Archive`-based compilation and
/// binary-archive caching (`QuadRenderer`'s M9 cache is `MTL3`-API and
/// stays QuadRenderer's) are the deliberate follow-up; construction here
/// pays the same synchronous compile `QuadRenderer` pays on a cold cache.
/// The blend state, pixel format, scissor math, viewport and draw
/// parameters replicate `QuadRenderer.draw` exactly — the pixel-equivalence
/// tests in `TerminalRenderBackendTests` enforce that the two stay in
/// lockstep.
///
/// **Resource lifetime (the part MTL4 makes explicit).** Ring-slot reuse is
/// gated on GPU completion: each commit signals `completionEvent` with the
/// frame number, and `beginFrame` for frame *N* waits — non-blocking check
/// first — for frame *N − frameSlotCount* before touching the allocator and
/// ring slots that frame used. A frame's draws *append* to that frame's
/// ring slot rather than rotating slots per draw call (Kitty image draws
/// can exceed the slot count within one frame, which a per-call rotation
/// would alias); a slot that outgrows its buffer mid-frame allocates a
/// larger one and retires the old — retired buffers are dropped only after
/// the current frame completes on the GPU. If the completion wait ever
/// times out (a full second: a GPU hang, not slow frames), the frame
/// allocates fresh buffers and a fresh allocator instead of overwriting
/// memory the GPU may still be reading.
///
/// Deallocation is the other half of that contract: address- and
/// resource-ID-based bindings are not retained by the command buffer the
/// way MTL3's object bindings are, so freeing the backend — its command
/// buffer, allocators, ring buffers, residency set — while a committed
/// frame is still executing is a driver-level `Invalid Resource` fault
/// (caught by `metal4BackendDeallocatesWithFramesInFlight` during B12
/// development). `deinit` therefore drains: it waits, bounded, for the
/// last committed frame before anything it owns is released.
///
/// **Residency.** The ring buffers sit in an `MTLResidencySet` attached to
/// the queue. Shared- and managed-storage resources are CPU-visible and
/// always resident on macOS, so strictly nothing here needs the set — every
/// texture this backend binds (the glyph atlases, Kitty image textures) is
/// `.managed`, and the drawable is Core Animation's, sequenced by
/// `waitForDrawable`/`signalDrawable`. The set exists because MTL4 makes
/// residency the caller's explicit responsibility for address-bound
/// resources and the cost of being explicit is one set commit per buffer
/// creation; the pixel-equivalence tests cover the texture path as proof.
///
/// **Selection.** Still opt-in (`CORTA_METAL4=1`) and capability-gated
/// (`supportsFamily(.metal4)`), selected by `TerminalRenderer.init`; a
/// throwing `init` there falls back to `QuadRenderer`, which remains the
/// default and is untouched. Whether MTL4 command submission helps Corta's
/// two-to-three-draws-a-frame workload at all is a measurement question —
/// the backend exists so that question can be answered with real numbers
/// rather than assumed (`RenderMetrics`, `CORTA_RENDER_METRICS=1`).
///
/// Threading: same contract as `QuadRenderer` — every method is called from
/// the render thread; the only cross-thread activity is the commit feedback
/// handler, which touches none of this type's state.
nonisolated final class Metal4Backend: TerminalRenderBackend, Metal4FrameBackend {
    let device: MTLDevice

    private let queue: any MTL4CommandQueue
    /// MTL4 command buffers are persistent, reusable objects (begin →
    /// encode → end → commit, then begin again), unlike MTL3's
    /// per-frame `MTLCommandBuffer`s — one for the life of the backend.
    private let commandBuffer: any MTL4CommandBuffer
    /// One allocator per in-flight frame slot: an allocator may be
    /// `reset()` only once every command buffer encoded with it has
    /// completed on the GPU, which the frame-completion gate in
    /// `beginFrame` guarantees before the slot is reused.
    private var allocators: [any MTL4CommandAllocator]
    /// Bindings for the one argument table every draw uses. Snapshot
    /// semantics ("Metal takes a snapshot of the resources in the argument
    /// table when you encode a draw") make rebinding between draws of one
    /// frame — and between frames while an earlier frame is in flight —
    /// safe.
    private let argumentTable: any MTL4ArgumentTable
    private let residencySet: any MTLResidencySet
    /// Signalled with the frame number after each frame's commit;
    /// `beginFrame` consults it before reusing anything frame
    /// *N − frameSlotCount* wrote (see the type's doc comment).
    private let completionEvent: MTLSharedEvent

    private let solidPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    /// The color-atlas variant of the glyph pipeline — premultiplied-source
    /// blending, mirroring `QuadRenderer.colorGlyphPipeline` exactly.
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// The render pass descriptor, created once and re-pointed at each
    /// frame's target — the MTL3 path likewise builds one descriptor per
    /// frame (`FrameScheduler.clearPass`), and reusing it here removes the
    /// last per-frame object allocation from the backend itself.
    private let renderPassDescriptor = MTL4RenderPassDescriptor()

    /// How many frames may be in flight — the depth of the allocator ring
    /// and of every `InstanceBufferRing` slot array.
    private static let frameSlotCount = 3

    /// 1-based count of frames begun so far. Also the value
    /// `completionEvent` is signalled with once a frame completes.
    private var frameNumber: UInt64 = 0
    /// Ring slot the current frame writes — `(frameNumber - 1) %
    /// frameSlotCount`, computed in `beginFrame`.
    private var currentSlot = 0
    /// Set when the completion wait in `beginFrame` times out: this frame
    /// must not overwrite anything a still-in-flight frame may be reading,
    /// so ring writes allocate fresh buffers instead (see the type comment).
    private var forceFreshResources = false

    /// Per-frame state, valid between `beginFrame` and `endFrame`. The
    /// render thread is the only caller, as with `QuadRenderer`.
    private var encoder: (any MTL4RenderCommandEncoder)?

    /// Buffers/allocators replaced mid-life (a grown ring slot, the
    /// timeout path) whose last reader may still be in flight, tagged with
    /// the frame that retired them. Dropped — and removed from the
    /// residency set — once the GPU has completed that frame.
    private var retiredBuffers: [(frame: UInt64, buffer: MTLBuffer)] = []
    private var retiredAllocators: [(frame: UInt64, allocator: any MTL4CommandAllocator)] = []

    /// Instance storage for one pipeline kind. One buffer per frame slot;
    /// every draw call of the kind within a frame *appends* its instances
    /// (plus that draw's uniforms) to the frame's slot rather than rotating
    /// slots per call, so a slot is written at most once per frame and the
    /// frame-level completion gate covers every write. Grows, never
    /// shrinks — the steady state allocates nothing (`PERFORMANCE.md` §3).
    private final class InstanceBufferRing {
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        /// Bytes appended to the current frame's slot so far.
        private var used = 0

        func beginFrame() {
            used = 0
        }

        /// Appends `instanceByteCount` bytes of instances plus `uniforms`
        /// to `slot`, returning their GPU addresses. `forceFresh` (the
        /// completion-timeout path) replaces the slot's buffer outright
        /// rather than copying into memory an in-flight frame may still
        /// be reading; growth does the same, since earlier draws this
        /// frame recorded the old buffer's addresses and keep reading it.
        func append(
            instances: UnsafeRawPointer, instanceByteCount: Int, uniforms: QuadUniforms,
            slot: Int, device: MTLDevice, forceFresh: Bool,
            residencySet: any MTLResidencySet, retire: (MTLBuffer) -> Void
        ) -> (instances: MTLGPUAddress, uniforms: MTLGPUAddress)? {
            let instanceOffset = Self.align(used)
            let uniformOffset = Self.align(instanceOffset + instanceByteCount)
            let needed = uniformOffset + MemoryLayout<QuadUniforms>.stride
            if forceFresh || buffers[slot] == nil || buffers[slot]!.length < needed {
                let newLength = max(needed, (buffers[slot]?.length ?? 0) * 2)
                guard
                    let fresh = device.makeBuffer(length: newLength, options: .storageModeShared)
                else { return nil }
                if let old = buffers[slot] {
                    // Retired but kept in the residency set until the GPU
                    // completes this frame (`dropRetired`): earlier draws
                    // of this frame recorded its addresses and still read
                    // it once committed.
                    retire(old)
                }
                buffers[slot] = fresh
                residencySet.addAllocation(fresh)
                residencySet.commit()
            }
            guard let buffer = buffers[slot] else { return nil }
            var uniforms = uniforms
            buffer.contents().advanced(by: instanceOffset)
                .copyMemory(from: instances, byteCount: instanceByteCount)
            withUnsafeBytes(of: &uniforms) { raw in
                guard let base = raw.baseAddress else { return }
                buffer.contents().advanced(by: uniformOffset)
                    .copyMemory(from: base, byteCount: raw.count)
            }
            used = needed
            return (buffer.gpuAddress + UInt64(instanceOffset), buffer.gpuAddress + UInt64(uniformOffset))
        }

        private static func align(_ offset: Int) -> Int {
            // `QuadInstance`/`QuadUniforms` contain SIMD vectors (alignment
            // 16); every offset into the buffer keeps that alignment so the
            // constant address space reads stay legal.
            (offset + 15) & ~15
        }
    }

    private let solidRing = InstanceBufferRing()
    private let glyphRing = InstanceBufferRing()
    private let colorGlyphRing = InstanceBufferRing()

    /// Whether `device` reports the Metal 4 GPU family. A capability fact
    /// only — selection additionally requires the `CORTA_METAL4` opt-in.
    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.metal4)
    }

    /// Opt-in, consulted alongside `isSupported(by:)` — see the type's doc
    /// comment for why this is not on by default for every capable device.
    static var isOptedIn: Bool {
        ProcessInfo.processInfo.environment["CORTA_METAL4"] == "1"
    }

    init(device: MTLDevice) throws {
        self.device = device
        let queueDescriptor = MTL4CommandQueueDescriptor()
        queueDescriptor.label = "Corta.metal4"
        self.queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
        guard let commandBuffer: any MTL4CommandBuffer = device.makeCommandBuffer() else {
            throw Metal4BackendError.commandBufferUnavailable
        }
        self.commandBuffer = commandBuffer
        var allocators: [any MTL4CommandAllocator] = []
        for _ in 0..<Self.frameSlotCount {
            guard let allocator: any MTL4CommandAllocator = device.makeCommandAllocator() else {
                throw Metal4BackendError.commandAllocatorUnavailable
            }
            allocators.append(allocator)
        }
        self.allocators = allocators

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        // buffer(0) instances, buffer(1) uniforms, texture(0) atlas,
        // sampler(0) — the same indices `Shaders.metal` declares.
        tableDescriptor.maxBufferBindCount = 2
        tableDescriptor.maxTextureBindCount = 1
        tableDescriptor.maxSamplerStateBindCount = 1
        tableDescriptor.initializeBindings = true
        tableDescriptor.label = "Corta.quad"
        self.argumentTable = try device.makeArgumentTable(descriptor: tableDescriptor)

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "Corta.metal4"
        self.residencySet = try device.makeResidencySet(descriptor: residencyDescriptor)
        queue.addResidencySet(residencySet)

        guard let event = device.makeSharedEvent() else {
            throw Metal4BackendError.sharedEventUnavailable
        }
        self.completionEvent = event

        // The pipelines mirror `QuadRenderer.init`'s descriptors exactly —
        // same shaders, pixel format and blend state, so the two backends
        // produce identical pixels for identical instances. No binary
        // archive here: QuadRenderer's M9 cache is built on the MTL3 API
        // and stays its own; an MTL4Archive/MTL4Compiler cache is the
        // follow-up.
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
            // accumulate as src.a + dst.a*(1-src.a).
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.solidPipeline = try makePipeline(fragment: solidFragment)
        self.glyphPipeline = try makePipeline(fragment: glyphFragment)
        self.colorGlyphPipeline = try makePipeline(fragment: colorGlyphFragment, premultipliedSource: true)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw QuadRendererError.samplerUnavailable
        }
        self.sampler = sampler
    }

    /// Waits for the last committed frame before anything this backend owns
    /// — the reusable command buffer, the allocators, the ring buffers, the
    /// residency set — is released: MTL4's address-based bindings are not
    /// retained by the command buffer the way MTL3's object bindings were,
    /// so releasing them mid-execution is a driver-level `Invalid Resource`
    /// fault. The wait is bounded: frames complete within a vsync or two in
    /// any live render loop, and past a second the GPU is hung and no wait
    /// would save the process anyway.
    deinit {
        if frameNumber > 0 {
            _ = completionEvent.wait(untilSignaledValue: frameNumber, timeoutMS: 1000)
        }
    }

    // MARK: - Metal4FrameBackend

    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String) {
        // A draw call outside a frame is a programming error in the one
        // driver (`TerminalRenderer.draw(through:)`); close whatever is
        // open rather than trapping or corrupting it.
        if encoder != nil { endFrame(presenting: nil, onCompleted: nil) }
        frameNumber += 1
        currentSlot = Int((frameNumber - 1) % UInt64(Self.frameSlotCount))

        let completed = completionEvent.signaledValue
        dropRetired(through: completed)

        // The slot this frame reuses was last written by frame
        // `frameNumber - frameSlotCount`; the GPU must be done with it
        // before the allocator is reset or a ring slot is rewritten.
        if frameNumber > UInt64(Self.frameSlotCount) {
            let predecessor = frameNumber - UInt64(Self.frameSlotCount)
            if completed < predecessor,
                !completionEvent.wait(untilSignaledValue: predecessor, timeoutMS: 1000)
            {
                // A second behind is not a slow frame, it is a hung GPU.
                // Allocate fresh resources for this frame rather than
                // overwrite memory in-flight work may still read.
                forceFreshResources = true
            }
        }

        if forceFreshResources {
            let retired = allocators[currentSlot]
            retiredAllocators.append((frame: frameNumber, allocator: retired))
            guard let fresh: any MTL4CommandAllocator = device.makeCommandAllocator() else {
                // Nothing to encode into: the frame is skipped, but
                // `endFrame` still runs and still presents the drawable —
                // an unpresented drawable is never recycled
                // (`FrameScheduler`'s replacement rule).
                forceFreshResources = false
                return
            }
            allocators[currentSlot] = fresh
        }
        let allocator = allocators[currentSlot]
        allocator.reset()

        commandBuffer.label = label
        commandBuffer.beginCommandBuffer(allocator: allocator)
        renderPassDescriptor.colorAttachments[0].texture = target
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            commandBuffer.endCommandBuffer()
            return
        }
        // Correlates a capture with which of the up-to-three passes a frame
        // took, same as the MTL3 path's per-encoder labels.
        encoder.label = label
        self.encoder = encoder
        solidRing.beginFrame()
        glyphRing.beginFrame()
        colorGlyphRing.beginFrame()
    }

    func drawSolidQuads(_ instances: [QuadInstance], rect: CGRect, drawableSize: CGSize) {
        draw(
            instances, ring: solidRing, pipeline: solidPipeline, atlas: nil,
            rect: rect, drawableSize: drawableSize, label: "Corta.solid")
    }

    func drawGlyphQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize
    ) {
        draw(
            instances, ring: glyphRing, pipeline: glyphPipeline, atlas: atlas,
            rect: rect, drawableSize: drawableSize, label: "Corta.glyph")
    }

    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize
    ) {
        draw(
            instances, ring: colorGlyphRing, pipeline: colorGlyphPipeline, atlas: atlas,
            rect: rect, drawableSize: drawableSize, label: "Corta.colorGlyph")
    }

    func endFrame(presenting drawable: (any MTLDrawable)?, onCompleted: (@Sendable () -> Void)?) {
        forceFreshResources = false
        guard encoder != nil else {
            // `beginFrame` failed to open the frame (allocator creation
            // under the timeout path, or encoder creation failed): there is
            // nothing to commit, but a drawable must still be presented —
            // see `FrameScheduler`'s replacement rule. The event is still
            // signalled so a later frame's completion wait never blocks on
            // a frame number nothing will ever commit.
            queue.signalEvent(completionEvent, value: frameNumber)
            drawable?.present()
            onCompleted?()
            return
        }
        encoder?.endEncoding()
        encoder = nil
        commandBuffer.endCommandBuffer()

        // `waitForDrawable` before committing work that targets the
        // drawable, per `MTL4CommandQueue`'s contract; CAMetalDisplayLink
        // has already resolved it, so this is a queue-side ordering, not a
        // CPU block.
        if let drawable {
            queue.waitForDrawable(drawable)
        }
        if let onCompleted {
            let options = MTL4CommitOptions()
            options.addFeedbackHandler { _ in onCompleted() }
            queue.commit([commandBuffer], options: options)
        } else {
            queue.commit([commandBuffer])
        }
        queue.signalEvent(completionEvent, value: frameNumber)
        if let drawable {
            // After committing everything that targets the drawable, before
            // presenting it — `MTL4CommandQueue.signalDrawable`'s contract.
            queue.signalDrawable(drawable)
            drawable.present()
        }
    }

    // MARK: - TerminalRenderBackend (the Metal-3-shaped base protocol)

    /// The base protocol predates the frame seam and is Metal-3-shaped —
    /// an MTL4 backend cannot accept a caller's `MTLCommandBuffer`. Nothing
    /// on the Metal 4 path reaches these (`ViewController.render(into:...)`
    /// branches on `Metal4FrameBackend` first); they forward to a
    /// lazily-built `QuadRenderer` so a stray caller through the base
    /// protocol still gets correct output rather than a dropped frame.
    private lazy var legacy: QuadRenderer? = try? QuadRenderer(device: device)

    func drawSolidQuads(
        _ instances: [QuadInstance], rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy?.drawSolidQuads(
            instances, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    func drawGlyphQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy?.drawGlyphQuads(
            instances, atlas: atlas, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer
    ) {
        legacy?.drawColorQuads(
            instances, atlas: atlas, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    // MARK: - Encoding

    /// The MTL4 counterpart of `QuadRenderer.draw` — same scissor, viewport,
    /// uniforms and draw parameters, bound through the argument table
    /// instead of `setVertexBuffer`/`setVertexBytes`.
    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        label: String
    ) {
        // The clear already happens at `beginFrame` — the render pass is
        // open regardless of instance count, exactly like the MTL3 path
        // running its first encoder for the `.clear` load action alone.
        guard let encoder, !instances.isEmpty else { return }

        // Clipping to `rect` via the scissor — identical math to
        // `QuadRenderer.draw`, which the pixel-equivalence tests hold equal.
        let x = max(0, Int(rect.minX.rounded(.down)))
        let y = max(0, Int(rect.minY.rounded(.down)))
        let maxWidth = max(0, Int(drawableSize.width) - x)
        let maxHeight = max(0, Int(drawableSize.height) - y)
        let width = min(Int(rect.width.rounded(.up)), maxWidth)
        let height = min(Int(rect.height.rounded(.up)), maxHeight)
        guard width > 0, height > 0 else { return }

        let uniforms = QuadUniforms(
            rectOrigin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            rectSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        )
        let instanceByteCount = MemoryLayout<QuadInstance>.stride * instances.count
        guard
            let addresses = instances.withUnsafeBytes({ raw -> (MTLGPUAddress, MTLGPUAddress)? in
                guard let base = raw.baseAddress else { return nil }
                return ring.append(
                    instances: base, instanceByteCount: instanceByteCount, uniforms: uniforms,
                    slot: currentSlot, device: device, forceFresh: forceFreshResources,
                    residencySet: residencySet
                ) { [self] buffer in
                    retiredBuffers.append((frame: frameNumber, buffer: buffer))
                }
            })
        else { return }
        argumentTable.setAddress(addresses.0, index: 0)
        argumentTable.setAddress(addresses.1, index: 1)
        if let atlas {
            argumentTable.setTexture(atlas.gpuResourceID, index: 0)
            argumentTable.setSamplerState(sampler.gpuResourceID, index: 0)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(drawableSize.width), height: Double(drawableSize.height),
                znear: 0, zfar: 1))
        encoder.pushDebugGroup(label)
        encoder.drawPrimitives(
            primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4,
            instanceCount: instances.count)
        encoder.popDebugGroup()
    }

    /// Releases retired buffers/allocators whose retiring frame the GPU has
    /// completed. Called from `beginFrame` with the last-known completed
    /// frame number.
    private func dropRetired(through completed: UInt64) {
        var keptBuffers: [(frame: UInt64, buffer: MTLBuffer)] = []
        var removedAny = false
        for entry in retiredBuffers {
            if entry.frame <= completed {
                residencySet.removeAllocation(entry.buffer)
                removedAny = true
            } else {
                keptBuffers.append(entry)
            }
        }
        if removedAny { residencySet.commit() }
        retiredBuffers = keptBuffers
        retiredAllocators.removeAll { $0.frame <= completed }
    }
}
