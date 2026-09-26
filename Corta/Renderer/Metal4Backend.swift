import CoreGraphics
import Foundation
import Metal
import OSLog

enum Metal4BackendError: Error {
    case commandBufferUnavailable
    case commandAllocatorUnavailable
}

/// Where Metal 4 backend faults are reported. A faulted commit or a queue
/// whose work never completes must be loud in the log — the silent
/// failure mode is a window that renders nothing (`Metal4Backend`'s
/// completion gate documents the degradation path).
nonisolated enum Metal4Diagnostics {
    static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render")

    private static let lock = NSLock()
    /// Bounded: a persistently faulting queue would otherwise log one
    /// error per frame forever.
    nonisolated(unsafe) private static var reportedFaults = 0

    static func reportCommitFault(_ error: any Error) {
        lock.lock()
        let reported = reportedFaults
        if reportedFaults < 8 { reportedFaults += 1 }
        lock.unlock()
        guard reported < 8 else { return }
        os_log(.error, log: log, "Metal 4 commit faulted: %{public}@", String(describing: error))
    }

    static func reportDeadQueue(timeouts: Int) {
        os_log(
            .fault, log: log,
            "Metal 4 GPU work has not completed across %d consecutive frames (commit fault or hung GPU); skipping frames instead of stalling the render loop",
            timeouts)
    }
}

/// A `TerminalRenderBackend` that submits through the Metal 4 command
/// submission API — `MTL4CommandQueue`, `MTL4CommandBuffer`,
/// `MTL4CommandAllocator`, `MTL4RenderCommandEncoder` and argument tables
/// (`MTL4ArgumentTable`) — rather than the `MTLCommandQueue`/
/// `MTLRenderCommandEncoder` path `QuadRenderer` uses.
///
/// **What is MTL4 here, and what is not.** Every frame is encoded into an
/// `MTL4CommandBuffer` (a persistent object, re-`begin`n each frame — MTL4
/// command buffers are reusable, unlike `MTL3`'s per-frame ones) through a
/// real `MTL4RenderCommandEncoder`, bound by address through one reused
/// argument table (`setAddress`/`setTexture`/`setSamplerState` — MTL4 has
/// no `setVertexBytes`, so uniforms live in the ring buffers alongside the
/// instances), committed to an `MTL4CommandQueue`, with drawable
/// presentation via `signalDrawable` + `MTLDrawable.present`. The pipeline
/// state objects are the classic `MTLRenderPipelineState` — that is not a
/// gap: `MTL4RenderCommandEncoder.setRenderPipelineState` takes exactly that
/// type, and MTL4's own compiler (`MTL4Compiler.newRenderPipelineState`)
/// returns it too. They come from `QuadPipelineCache`, shared with
/// `QuadRenderer`, so construction here costs a dictionary lookup once any
/// pane has run, and the `MTLBinaryArchive` warm-up (which lives in the
/// cache's creation path) covers this backend too — no
/// `MTL4Compiler`/`MTL4Archive`-specific cache is needed. The blend state, pixel format, scissor math,
/// viewport and draw parameters replicate `QuadRenderer.draw` exactly — the
/// pixel-equivalence tests in `TerminalRenderBackendTests` enforce that the
/// two stay in lockstep.
///
/// **Resource lifetime (the part MTL4 makes explicit).** Ring-slot reuse is
/// gated on GPU completion: each commit's feedback handler records the
/// frame number into `completedFrame`, and `beginFrame` for frame *N* waits
/// — non-blocking check first — for frame *N − frameSlotCount* before
/// touching the allocator and ring slots that frame used. A frame's draws *append* to that frame's
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
/// (`metal4BackendDeallocatesWithFramesInFlight` holds this). `deinit`
/// therefore drains: it waits, bounded, for the
/// last committed frame before anything it owns is released.
///
/// **Residency.** The ring buffers sit in an `MTLResidencySet` attached to
/// the queue — and so does every texture ever bound by resource ID
/// (`boundTextures`): MTL4 neither retains nor implicitly keeps resident a
/// texture bound by `gpuResourceID`, and one that is not resident faults at
/// read time — `.managed` storage included; MTL3's automatic residency does
/// not apply to argument-table bindings (the launch-time
/// `kIOGPUCommandBufferCallbackErrorPageFault` of the first live run). The
/// drawable is Core Animation's and is sequenced by
/// `waitForDrawable`/`signalDrawable` instead.
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
    /// encode → end → commit, then begin again), unlike MTL3's per-frame
    /// `MTLCommandBuffer`s — but re-beginning one while its previous commit
    /// is still executing faults intermittently at the driver level
    /// (`IOGPUMetalError`, observed on the very first frames of an app
    /// launch), so there is one per in-flight frame slot, rotated with the
    /// allocators: the frame-completion gate in `beginFrame` guarantees a
    /// slot's command buffer is quiescent before it is begun again.
    private var commandBuffers: [any MTL4CommandBuffer]
    /// One allocator per in-flight frame slot: an allocator may be
    /// `reset()` only once every command buffer encoded with it has
    /// completed on the GPU, which the same gate guarantees.
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
    ///
    /// Implemented on commit-feedback handlers, not a queue-signalled
    /// `MTLSharedEvent`: the feedback handler demonstrably fires for every
    /// commit (it is also where commit faults arrive), while the
    /// queue-level event was observed never to advance against a live
    /// `CAMetalDisplayLink` drawable stream — every `beginFrame` past the
    /// ring depth then waited out its full timeout and the window rendered
    /// ~1 frame/second.
    private let completion = FrameCompletion()

    /// The one piece of state the commit-feedback thread touches: the
    /// highest frame number whose feedback has arrived, behind its own
    /// condition. Boxed separately from the backend so the `@Sendable`
    /// feedback handler captures exactly this and never `self` — the
    /// backend's other state is render-thread-only and not `Sendable`,
    /// and the compiler was right to say so.
    private final class FrameCompletion: @unchecked Sendable {
        private let lock = NSCondition()
        private var completedFrame: UInt64 = 0

        var completed: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return completedFrame
        }

        /// Records a frame's completion and wakes any waiter.
        func note(_ frame: UInt64) {
            lock.lock()
            if frame > completedFrame { completedFrame = frame }
            lock.signal()
            lock.unlock()
        }

        /// Blocks until `frame` has completed or `deadline` passes;
        /// returns whether it completed.
        func wait(for frame: UInt64, until deadline: Date) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            while completedFrame < frame && Date() < deadline {
                lock.wait(until: deadline)
            }
            return completedFrame >= frame
        }
    }

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

    /// 1-based count of frames begun so far. Also the value a frame's
    /// commit-feedback handler records into `completedFrame`.
    private var frameNumber: UInt64 = 0
    /// Ring slot the current frame writes — `(frameNumber - 1) %
    /// frameSlotCount`, computed in `beginFrame`.
    private var currentSlot = 0
    /// Set when the completion wait in `beginFrame` times out: this frame
    /// must not overwrite anything a still-in-flight frame may be reading,
    /// so ring writes allocate fresh buffers instead (see the type comment).
    private var forceFreshResources = false

    /// Consecutive `beginFrame` completion-wait timeouts. A queue whose
    /// commits fault never delivers completion feedback, and the naive
    /// behaviour then is a one-second stall plus fresh allocator, command
    /// buffer and ring buffers on *every* frame — the "renders nothing at
    /// 1 fps while leaking" failure observed live when the drawable path
    /// faulted at launch. Past `completionTimeoutLimit` the queue is
    /// treated as dead: frames stop encoding entirely (`beginFrame`
    /// returns encoder-less, `endFrame` still presents the drawable and
    /// records the frame complete), which is cheap, bounded, and logged —
    /// and recovers by itself if feedback ever does arrive again.
    private var consecutiveCompletionTimeouts = 0
    private static let completionTimeoutLimit = 3

    /// Per-frame state, valid between `beginFrame` and `endFrame`. The
    /// render thread is the only caller, as with `QuadRenderer`.
    private var encoder: (any MTL4RenderCommandEncoder)?
    /// What the open encoder was last told: one encoder serves
    /// every draw of the frame and all draws share the pane's rect, so
    /// re-setting identical scissor, viewport or pipeline state per draw is
    /// a redundant state change. Reset in `beginFrame` — the MTL3 path has
    /// no equivalent to dedupe because each of its draws opens a fresh
    /// encoder and must set everything.
    private var lastScissor: MTLScissorRect?
    private var lastViewport: MTLViewport?
    private var lastPipeline: (any MTLRenderPipelineState)?

    /// Textures ever bound by resource ID, with the last frame that bound
    /// them. MTL4 does not retain or implicitly keep resident a texture
    /// bound by `gpuResourceID` the way MTL3's object bindings did: a bound
    /// texture that is not in the queue's residency set faults at read time
    /// (the launch-time `kIOGPUCommandBufferCallbackErrorPageFault` this
    /// table fixes), and a texture freed while a frame that references it
    /// is in flight faults the same way — so entries here retain the
    /// texture, and `dropRetired` releases both the retention and the
    /// residency only once the last binding frame has completed on the GPU
    /// plus `textureRetentionFrames` more (see that constant for why not
    /// immediately).
    private var boundTextures: [ObjectIdentifier: (texture: MTLTexture, lastFrame: UInt64)] = [:]
    /// How many completed frames a bound texture stays resident past its
    /// last binding frame. Zero would be correct but churns: with the GPU
    /// keeping up, the atlas bound by frame *N* is already complete when
    /// frame *N + 1* begins, so it would leave the residency set in
    /// `dropRetired` and re-enter it in `makeResident` — two
    /// `MTLResidencySet.commit()`s per frame, per texture, for a texture
    /// that is bound every frame. The grace keeps the atlas (and a Kitty
    /// placement's texture) resident across the frames that reuse it; a
    /// texture the renderer has actually dropped is released once this
    /// many further frames have completed — bounded by frames, so an idle
    /// pane holds it no longer than its next second of drawing.
    private static let textureRetentionFrames: UInt64 = 60

    /// Buffers/allocators replaced mid-life (a grown ring slot, the
    /// timeout path) whose last reader may still be in flight, tagged with
    /// the frame that retired them. Dropped — and removed from the
    /// residency set — once the GPU has completed that frame.
    private var retiredBuffers: [(frame: UInt64, buffer: MTLBuffer)] = []
    private var retiredAllocators: [(frame: UInt64, allocator: any MTL4CommandAllocator)] = []
    private var retiredCommandBuffers: [(frame: UInt64, commandBuffer: any MTL4CommandBuffer)] = []

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
        var commandBuffers: [any MTL4CommandBuffer] = []
        var allocators: [any MTL4CommandAllocator] = []
        for _ in 0..<Self.frameSlotCount {
            guard let commandBuffer: any MTL4CommandBuffer = device.makeCommandBuffer() else {
                throw Metal4BackendError.commandBufferUnavailable
            }
            commandBuffers.append(commandBuffer)
            guard let allocator: any MTL4CommandAllocator = device.makeCommandAllocator() else {
                throw Metal4BackendError.commandAllocatorUnavailable
            }
            allocators.append(allocator)
        }
        self.commandBuffers = commandBuffers
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

        // The pipelines and sampler are shared with `QuadRenderer` through
        // `QuadPipelineCache` — same shaders, pixel format and blend
        // state, so the two backends produce identical pixels for identical
        // instances, and a pane pays the compile at most once per process
        // whichever backend it gets. The `MTLBinaryArchive` warm-up
        // covers this backend too: it lives in the cache's creation path,
        // and the pipelines are classic `MTLRenderPipelineState`s whichever
        // submission API encodes them — no MTL4Archive/MTL4Compiler port
        // is needed for the warm-up to apply here.
        let pipelines = try QuadPipelineCache.entry(for: device)
        self.solidPipeline = pipelines.solidPipeline
        self.glyphPipeline = pipelines.glyphPipeline
        self.colorGlyphPipeline = pipelines.colorGlyphPipeline
        self.sampler = pipelines.sampler
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
            _ = completion.wait(for: frameNumber, until: Date().addingTimeInterval(1))
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

        let completed = completion.completed
        dropRetired(through: completed)

        // The slot this frame reuses was last written by frame
        // `frameNumber - frameSlotCount`; the GPU must be done with it
        // before the allocator is reset or a ring slot is rewritten.
        if frameNumber > UInt64(Self.frameSlotCount) {
            let predecessor = frameNumber - UInt64(Self.frameSlotCount)
            var caughtUp = completed >= predecessor
            if !caughtUp {
                caughtUp = completion.wait(
                    for: predecessor, until: Date().addingTimeInterval(1))
            }
            if !caughtUp {
                // A second behind is not a slow frame, it is a hung GPU.
                // Allocate fresh resources for this frame rather than
                // overwrite memory in-flight work may still read.
                forceFreshResources = true
                consecutiveCompletionTimeouts += 1
                if consecutiveCompletionTimeouts == Self.completionTimeoutLimit {
                    Metal4Diagnostics.reportDeadQueue(timeouts: consecutiveCompletionTimeouts)
                }
            } else {
                consecutiveCompletionTimeouts = 0
            }
        }

        if consecutiveCompletionTimeouts >= Self.completionTimeoutLimit {
            // The queue is dead (a faulting commit never signals the
            // completion event): stop encoding — one second of stall and a
            // full set of fresh resources per frame is the failure this
            // caps. `endFrame` still presents the drawable and signals the
            // event number, so the scheduler and later waits are undisturbed;
            // if the event ever advances again the timeout counter resets
            // above and encoding resumes.
            forceFreshResources = false
            return
        }

        if forceFreshResources {
            let retired = allocators[currentSlot]
            retiredAllocators.append((frame: frameNumber, allocator: retired))
            // The slot's command buffer may equally still be executing —
            // the wait that failed was precisely the guarantee that it is
            // not — so it is retired and replaced along with the allocator.
            retiredCommandBuffers.append(
                (frame: frameNumber, commandBuffer: commandBuffers[currentSlot]))
            guard let freshAllocator: any MTL4CommandAllocator = device.makeCommandAllocator(),
                let freshCommandBuffer: any MTL4CommandBuffer = device.makeCommandBuffer()
            else {
                // Nothing to encode into: the frame is skipped, but
                // `endFrame` still runs and still presents the drawable —
                // an unpresented drawable is never recycled
                // (`FrameScheduler`'s replacement rule).
                forceFreshResources = false
                return
            }
            allocators[currentSlot] = freshAllocator
            commandBuffers[currentSlot] = freshCommandBuffer
        }
        let allocator = allocators[currentSlot]
        allocator.reset()
        let commandBuffer = commandBuffers[currentSlot]

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
        lastScissor = nil
        lastViewport = nil
        lastPipeline = nil
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

    func endFrame(
        presenting drawable: (any MTLDrawable)?, onCompleted: (@Sendable ((any Error)?) -> Void)?
    ) {
        forceFreshResources = false
        guard encoder != nil else {
            // `beginFrame` failed to open the frame (allocator creation
            // under the timeout path, or encoder creation failed): there is
            // nothing to commit, but a drawable must still be presented —
            // see `FrameScheduler`'s replacement rule. The frame is still
            // recorded complete so a later frame's completion wait never
            // blocks on a frame number nothing will ever commit.
            completion.note(frameNumber)
            drawable?.present()
            onCompleted?(nil)
            return
        }
        encoder?.endEncoding()
        encoder = nil
        let commandBuffer = commandBuffers[currentSlot]
        commandBuffer.endCommandBuffer()

        // `waitForDrawable` before committing work that targets the
        // drawable, per `MTL4CommandQueue`'s contract; CAMetalDisplayLink
        // has already resolved it, so this is a queue-side ordering, not a
        // CPU block.
        if let drawable {
            queue.waitForDrawable(drawable)
        }
        // The feedback handler is the completion gate (`completedFrame`) as
        // well as the caller's metrics hook — always attached: it is the
        // one commit-lifecycle callback MTL4 reliably delivers here.
        let options = MTL4CommitOptions()
        let frame = frameNumber
        let completion = completion
        options.addFeedbackHandler { feedback in
            // A faulted commit is loud, once per fault, bounded — the
            // alternative is a window that silently renders nothing.
            if let error = feedback.error {
                Metal4Diagnostics.reportCommitFault(error)
            }
            completion.note(frame)
            onCompleted?(feedback.error)
        }
        queue.commit([commandBuffer], options: options)
        if let drawable {
            // After committing everything that targets the drawable, before
            // presenting it — `MTL4CommandQueue.signalDrawable`'s contract.
            queue.signalDrawable(drawable)
            RenderMetrics.notePresent(of: drawable)
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
            makeResident(atlas)
            argumentTable.setTexture(atlas.gpuResourceID, index: 0)
            argumentTable.setSamplerState(sampler.gpuResourceID, index: 0)
        }

        if lastPipeline !== pipeline {
            encoder.setRenderPipelineState(pipeline)
            lastPipeline = pipeline
        }
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        let scissor = MTLScissorRect(x: x, y: y, width: width, height: height)
        let scissorIsCurrent =
            lastScissor.map {
                $0.x == scissor.x && $0.y == scissor.y
                    && $0.width == scissor.width && $0.height == scissor.height
            } ?? false
        if !scissorIsCurrent {
            encoder.setScissorRect(scissor)
            lastScissor = scissor
        }
        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableSize.width), height: Double(drawableSize.height),
            znear: 0, zfar: 1)
        let viewportIsCurrent =
            lastViewport.map {
                $0.originX == viewport.originX && $0.originY == viewport.originY
                    && $0.width == viewport.width && $0.height == viewport.height
                    && $0.znear == viewport.znear && $0.zfar == viewport.zfar
            } ?? false
        if !viewportIsCurrent {
            encoder.setViewport(viewport)
            lastViewport = viewport
        }
        encoder.pushDebugGroup(label)
        encoder.drawPrimitives(
            primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4,
            instanceCount: instances.count)
        encoder.popDebugGroup()
    }

    /// Keeps a bound texture alive and in the residency set until every
    /// frame that has bound it has completed — see `boundTextures`.
    private func makeResident(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        if boundTextures[id] == nil {
            residencySet.addAllocation(texture)
            residencySet.commit()
        }
        boundTextures[id] = (texture: texture, lastFrame: frameNumber)
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
        let expiredTextures = boundTextures.filter {
            $0.value.lastFrame + Self.textureRetentionFrames <= completed
        }
        for (id, entry) in expiredTextures {
            residencySet.removeAllocation(entry.texture)
            boundTextures.removeValue(forKey: id)
            removedAny = true
        }
        if removedAny { residencySet.commit() }
        retiredBuffers = keptBuffers
        retiredAllocators.removeAll { $0.frame <= completed }
        retiredCommandBuffers.removeAll { $0.frame <= completed }
    }
}
