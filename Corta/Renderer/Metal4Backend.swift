// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Metal
import OSLog

enum Metal4BackendError: Error {
    case commandBufferUnavailable
    case commandAllocatorUnavailable
}

/// Where Metal 4 backend faults are logged; the silent failure mode would
/// be a window that renders nothing.
nonisolated enum Metal4Diagnostics {
    static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render")

    private static let lock = NSLock()
    /// Bounded, or a faulting queue logs once per frame forever.
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

/// A `TerminalRenderBackend` that submits through the Metal 4 API
/// (`MTL4CommandQueue`, `MTL4CommandBuffer`, `MTL4CommandAllocator`,
/// `MTL4RenderCommandEncoder`, one reused `MTL4ArgumentTable`) instead of
/// `QuadRenderer`'s `MTLCommandQueue` path.
///
/// Draws bind by address through the argument table (MTL4 has no
/// `setVertexBytes`, so uniforms ride in the ring buffers), and the
/// drawable is presented via `signalDrawable`. Pipelines are classic
/// `MTLRenderPipelineState`s, which MTL4 encoders take, shared with
/// `QuadRenderer` through `QuadPipelineCache`. Blend, scissor, viewport
/// and draw parameters replicate `QuadRenderer.draw`;
/// `TerminalRenderBackendTests` holds the two pixel-equivalent.
///
/// **Resource lifetime.** Ring-slot reuse is gated on GPU completion:
/// commit feedback records each frame into `completion`, and `beginFrame`
/// for frame *N* waits for *N − frameSlotCount* before reusing its
/// allocator and slots. A frame's draws append to its slot (Kitty draws can
/// outnumber slots); a slot that outgrows its buffer retires the old one
/// until the frame completes. A wait that times out (a second: a hung GPU)
/// allocates fresh resources instead of overwriting in-flight memory.
/// Address bindings aren't retained by the command buffer, so `deinit`
/// drains the last committed frame before releasing anything
/// (`metal4BackendDeallocatesWithFramesInFlight`).
///
/// **Residency.** Ring buffers and every texture bound by resource ID
/// (`boundTextures`) live in the queue's `MTLResidencySet`: MTL4 neither
/// retains nor keeps resident a texture bound by `gpuResourceID`, and a
/// non-resident one page-faults at read time.
///
/// **Selection.** Opt-in (`CORTA_METAL4=1`) and gated on
/// `supportsFamily(.metal4)` by `TerminalRenderer.init`, which falls back
/// to `QuadRenderer` if `init` throws. Measure with
/// `CORTA_RENDER_METRICS=1`.
///
/// Every method runs on the render thread; only the commit feedback
/// handler runs elsewhere, and it touches only `completion`.
nonisolated final class Metal4Backend: TerminalRenderBackend, Metal4FrameBackend {
    let device: MTLDevice

    private let queue: any MTL4CommandQueue
    /// One per in-flight slot: re-beginning a command buffer whose previous
    /// commit is still executing faults intermittently (`IOGPUMetalError` on
    /// launch), and the completion gate keeps a slot's buffer quiescent.
    private var commandBuffers: [any MTL4CommandBuffer]
    /// One per slot: an allocator may be reset only after its work completes.
    private var allocators: [any MTL4CommandAllocator]
    /// Metal snapshots the table at each draw, so rebinding between draws and
    /// frames is safe.
    private let argumentTable: any MTL4ArgumentTable
    private let residencySet: any MTLResidencySet
    /// Fed from commit-feedback handlers, not a queue-signalled
    /// `MTLSharedEvent`: feedback fires for every commit, while the event was
    /// observed never to advance against a live `CAMetalDisplayLink` stream,
    /// capping the window at about 1 frame/second.
    private let completion = FrameCompletion()

    /// The highest completed frame, behind its own condition. Boxed so the
    /// `@Sendable` feedback handler captures this, never the non-`Sendable`
    /// backend.
    private final class FrameCompletion: @unchecked Sendable {
        private let lock = NSCondition()
        private var completedFrame: UInt64 = 0

        var completed: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return completedFrame
        }

        func note(_ frame: UInt64) {
            lock.lock()
            if frame > completedFrame { completedFrame = frame }
            lock.signal()
            lock.unlock()
        }

        /// Blocks until `frame` completes or `deadline` passes; true if it did.
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
    /// Premultiplied-source blending, as `QuadRenderer.colorGlyphPipeline`.
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// Created once and re-pointed each frame: no per-frame allocation.
    private let renderPassDescriptor = MTL4RenderPassDescriptor()

    /// Frames in flight: the depth of every per-slot ring.
    private static let frameSlotCount = 3

    /// 1-based count of frames begun; what a frame's feedback records.
    private var frameNumber: UInt64 = 0
    private var currentSlot = 0
    /// The completion wait timed out: this frame allocates fresh buffers.
    private var forceFreshResources = false

    /// Consecutive completion-wait timeouts. A faulting queue never delivers
    /// feedback, and every frame would stall a second and allocate fresh
    /// resources (observed live). Past `completionTimeoutLimit` frames stop
    /// encoding but still present and record completion — cheap, bounded and
    /// logged — and encoding resumes if feedback returns.
    private var consecutiveCompletionTimeouts = 0
    private static let completionTimeoutLimit = 3

    /// Valid between `beginFrame` and `endFrame`.
    private var encoder: (any MTL4RenderCommandEncoder)?
    /// The encoder's last state, so draws sharing one encoder skip redundant
    /// changes. Reset in `beginFrame`.
    private var lastScissor: MTLScissorRect?
    private var lastViewport: MTLViewport?
    private var lastPipeline: (any MTLRenderPipelineState)?

    /// Textures bound by resource ID, with their last binding frame. Retained
    /// and resident, since MTL4 does neither for `gpuResourceID` bindings;
    /// `dropRetired` releases them `textureRetentionFrames` after that frame
    /// completes.
    private var boundTextures: [ObjectIdentifier: (texture: MTLTexture, lastFrame: UInt64)] = [:]
    /// Grace frames before an unbound texture leaves the residency set. Zero
    /// would be correct but would commit the residency set twice a frame for
    /// an atlas bound every frame.
    private static let textureRetentionFrames: UInt64 = 60

    /// Buffers replaced mid-life (a grown slot, the timeout path), tagged
    /// with the retiring frame; dropped once the GPU completes it.
    private var retiredBuffers: [(frame: UInt64, buffer: MTLBuffer)] = []
    private var retiredAllocators: [(frame: UInt64, allocator: any MTL4CommandAllocator)] = []
    private var retiredCommandBuffers: [(frame: UInt64, commandBuffer: any MTL4CommandBuffer)] = []

    /// Instance storage for one pipeline kind, one buffer per slot. Draws
    /// append (instances plus uniforms) to the frame's slot, so the frame-level
    /// gate covers every write. Grows, never shrinks (`PERFORMANCE.md` §3).
    private final class InstanceBufferRing {
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        private var used = 0

        func beginFrame() {
            used = 0
        }

        /// Appends instances plus uniforms to `slot`, returning GPU addresses.
        /// `forceFresh` and growth replace the buffer rather than write memory an
        /// in-flight frame, or an earlier draw of this one, still reads.
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
                    // Stays resident until this frame completes: earlier draws
                    // recorded its addresses.
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
            // SIMD members need 16-byte alignment in the constant address space.
            (offset + 15) & ~15
        }
    }

    private let solidRing = InstanceBufferRing()
    private let glyphRing = InstanceBufferRing()
    private let colorGlyphRing = InstanceBufferRing()

    /// The capability alone; selection also needs `isOptedIn`.
    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.metal4)
    }

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
        // sampler(0) — as `Shaders.metal` declares.
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

        // Shared with `QuadRenderer`: identical pixels, one compile per process,
        // and the `MTLBinaryArchive` warm-up applies to both.
        let pipelines = try QuadPipelineCache.entry(for: device)
        self.solidPipeline = pipelines.solidPipeline
        self.glyphPipeline = pipelines.glyphPipeline
        self.colorGlyphPipeline = pipelines.colorGlyphPipeline
        self.sampler = pipelines.sampler
    }

    /// Waits, bounded to a second, for the last committed frame: releasing
    /// address-bound resources mid-execution is an `Invalid Resource` fault.
    deinit {
        if frameNumber > 0 {
            _ = completion.wait(for: frameNumber, until: Date().addingTimeInterval(1))
        }
    }

    // MARK: - Metal4FrameBackend

    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String) {
        // A frame left open is a bug in `TerminalRenderer.draw(through:)`;
        // close it rather than trap.
        if encoder != nil { endFrame(presenting: nil, onCompleted: nil) }
        frameNumber += 1
        currentSlot = Int((frameNumber - 1) % UInt64(Self.frameSlotCount))

        let completed = completion.completed
        dropRetired(through: completed)

        // Frame `frameNumber - frameSlotCount` last wrote this slot.
        if frameNumber > UInt64(Self.frameSlotCount) {
            let predecessor = frameNumber - UInt64(Self.frameSlotCount)
            var caughtUp = completed >= predecessor
            if !caughtUp {
                caughtUp = completion.wait(
                    for: predecessor, until: Date().addingTimeInterval(1))
            }
            if !caughtUp {
                // A second behind is a hung GPU, not a slow frame.
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
            // The queue is dead (see `consecutiveCompletionTimeouts`): stop
            // encoding. `endFrame` still presents and records completion.
            forceFreshResources = false
            return
        }

        if forceFreshResources {
            let retired = allocators[currentSlot]
            retiredAllocators.append((frame: frameNumber, allocator: retired))
            // The slot's command buffer may still be executing too.
            retiredCommandBuffers.append(
                (frame: frameNumber, commandBuffer: commandBuffers[currentSlot]))
            guard let freshAllocator: any MTL4CommandAllocator = device.makeCommandAllocator(),
                let freshCommandBuffer: any MTL4CommandBuffer = device.makeCommandBuffer()
            else {
                // Skipped, but `endFrame` still presents: an unpresented drawable is
                // never recycled (`FrameScheduler`).
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
            // Nothing to commit, but the drawable must still be presented, and the
            // frame recorded complete so no later wait blocks on it.
            completion.note(frameNumber)
            drawable?.present()
            onCompleted?(nil)
            return
        }
        encoder?.endEncoding()
        encoder = nil
        let commandBuffer = commandBuffers[currentSlot]
        commandBuffer.endCommandBuffer()

        // `MTL4CommandQueue`'s contract; a queue-side ordering, not a CPU block.
        if let drawable {
            queue.waitForDrawable(drawable)
        }
        // Always attached: it is the completion gate as well as the metrics hook.
        let options = MTL4CommitOptions()
        let frame = frameNumber
        let completion = completion
        options.addFeedbackHandler { feedback in
            if let error = feedback.error {
                Metal4Diagnostics.reportCommitFault(error)
            }
            completion.note(frame)
            onCompleted?(feedback.error)
        }
        queue.commit([commandBuffer], options: options)
        if let drawable {
            // After the commits targeting it, before presenting (MTL4 contract).
            queue.signalDrawable(drawable)
            RenderMetrics.notePresent(of: drawable)
            drawable.present()
        }
    }

    // MARK: - TerminalRenderBackend (the Metal-3-shaped base protocol)

    /// The base protocol is Metal-3-shaped and can't take a caller's
    /// `MTLCommandBuffer`. Nothing on the MTL4 path calls it; a stray caller
    /// gets a lazily built `QuadRenderer` rather than a dropped frame.
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

    /// `QuadRenderer.draw`, bound through the argument table.
    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        label: String
    ) {
        // The pass (and its clear) opened in `beginFrame`.
        guard let encoder, !instances.isEmpty else { return }

        // Same scissor math as `QuadRenderer.draw`.
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

    /// See `boundTextures`.
    private func makeResident(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        if boundTextures[id] == nil {
            residencySet.addAllocation(texture)
            residencySet.commit()
        }
        boundTextures[id] = (texture: texture, lastFrame: frameNumber)
    }

    /// Releases retired resources whose retiring frame has completed.
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
