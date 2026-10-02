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
    /// The GPU has no `MTLGPUFamily.metal4` — a virtual machine's
    /// paravirtual device; every Apple silicon Mac has it (D21).
    case metal4Unsupported
    case commandBufferUnavailable
    case commandAllocatorUnavailable
    /// Handed to `onCompleted` for a frame that was presented without being
    /// drawn, because its slot's previous frame had not completed.
    case frameDropped
}

/// Where backend faults are logged; the silent failure mode would be a
/// window that renders nothing.
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

    static func reportStalledQueue(droppedFrames: Int) {
        os_log(
            .fault, log: log,
            "Metal 4 GPU work has not completed across %d consecutive frames (commit fault or hung GPU); dropping frames instead of blocking the render loop",
            droppedFrames)
    }
}

/// The renderer's GPU backend: Metal 4 submission (`MTL4CommandQueue`,
/// per-slot `MTL4CommandBuffer`s and `MTL4CommandAllocator`s, one
/// `MTL4RenderCommandEncoder` per frame, one reused `MTL4ArgumentTable`).
///
/// **One render pass per frame.** `beginFrame` opens the pass and its
/// clear; every draw of the frame — backgrounds, glyphs, colour glyphs,
/// each Kitty placement — encodes into that one encoder; `endFrame` ends it
/// and commits. No draw pays a tile load/store round trip of its own.
///
/// Draws bind by address through the argument table (MTL4 has no
/// `setVertexBytes`, so uniforms ride in the ring buffers), and the drawable
/// is presented via `signalDrawable`. Pipelines are `MTLRenderPipelineState`s
/// from `QuadPipelineCache`, which is the type an MTL4 encoder takes.
///
/// **Frame slots.** A frame writes its slot's command buffer, allocator and
/// ring buffers, so it may begin only once the frame that last used the
/// slot has completed. Each slot has a semaphore; the commit-feedback
/// handler of the slot's frame signals it — the completion is an event, not
/// something polled. `beginFrame` waits for it at most `slotWaitLimit`, one
/// display frame; past that it drops the frame (presented, not drawn), and
/// while the slot stays busy later frames drop without waiting at all. So a
/// stalled GPU costs dropped frames, never a blocked main thread. Feedback
/// rather than a queue-signalled `MTLSharedEvent`: the event was observed
/// never to advance against a live `CAMetalDisplayLink` stream
/// (`history/2026-09-15-B12-METAL4-BACKEND.md`).
///
/// **Residency.** Ring buffers and every texture bound by resource ID
/// (`boundTextures`) live in the queue's `MTLResidencySet`: MTL4 neither
/// retains nor keeps resident a texture bound by `gpuResourceID`, and a
/// non-resident one page-faults at read time. Address bindings aren't
/// retained by the command buffer either, so `deinit` waits, bounded, for
/// the frames in flight (`metal4BackendDeallocatesWithFramesInFlight`).
///
/// Every method runs on the render thread; only the commit feedback
/// handler runs elsewhere, and it touches only `completion` and the slot
/// semaphores.
public nonisolated final class Metal4Backend {
    let device: MTLDevice

    private let queue: any MTL4CommandQueue
    /// One per slot: re-beginning a command buffer whose previous commit is
    /// still executing faults intermittently (`IOGPUMetalError` on launch).
    private let commandBuffers: [any MTL4CommandBuffer]
    /// One per slot: an allocator may be reset only after its work completes.
    private let allocators: [any MTL4CommandAllocator]
    /// Metal snapshots the table at each draw, so rebinding between draws and
    /// frames is safe.
    private let argumentTable: any MTL4ArgumentTable
    private let residencySet: any MTLResidencySet

    private let solidPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    /// Premultiplied-source blending, for colour glyphs and images.
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// Created once and re-pointed each frame: no per-frame allocation.
    private let renderPassDescriptor = MTL4RenderPassDescriptor()

    /// Frames in flight: the depth of every per-slot ring.
    static let frameSlotCount = 3

    /// How long `beginFrame` may wait for a busy slot: one frame at 60 Hz,
    /// the longest a display-link frame waits for its drawable.
    public static let defaultSlotWaitLimit: DispatchTimeInterval = .microseconds(16_667)
    private let slotWaitLimit: DispatchTimeInterval

    /// Signalled by the feedback handler of the frame that last used the
    /// slot; a slot is free when its semaphore can be taken.
    private let slotSemaphores: [DispatchSemaphore]
    /// The highest completed frame, for releasing retired resources.
    private let completion = FrameCompletion()

    /// Written by the feedback handler, read by `beginFrame`.
    private final class FrameCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completedFrame: UInt64 = 0

        var completed: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return completedFrame
        }

        func note(_ frame: UInt64) {
            lock.lock()
            if frame > completedFrame { completedFrame = frame }
            lock.unlock()
        }
    }

    /// 1-based count of frames committed; what a frame's feedback records.
    private var frameNumber: UInt64 = 0
    /// The slot the next committed frame uses. Advances only on a commit, so
    /// a dropped frame leaves the ring where it was.
    private var nextSlot = 0
    private var currentSlot = 0
    /// Frames dropped in a row; while non-zero, the next frame does not wait.
    private var consecutiveDroppedFrames = 0
    private static let stalledQueueReportThreshold = 3
    private(set) var droppedFrameCount = 0

    /// Valid between `beginFrame` and `endFrame`; nil for a dropped frame.
    private var encoder: (any MTL4RenderCommandEncoder)?
    /// The encoder's last state, so draws sharing one encoder skip redundant
    /// changes. Reset in `beginFrame`.
    private var lastScissor: MTLScissorRect?
    private var lastViewport: MTLViewport?
    private var lastPipeline: (any MTLRenderPipelineState)?

    /// Textures bound by resource ID, with their last binding frame. Retained
    /// and resident, since MTL4 does neither for `gpuResourceID` bindings;
    /// `dropRetired` releases image textures once that frame completes;
    /// persistent atlases retain a `textureRetentionFrames` grace period.
    private var boundTextures: [ObjectIdentifier: (texture: MTLTexture, lastFrame: UInt64, retentionFrames: UInt64)] = [:]
    /// Grace frames before an unbound texture leaves the residency set. Zero
    /// would be correct but would commit the residency set twice a frame for
    /// an atlas bound every frame.
    private static let textureRetentionFrames: UInt64 = 60

    /// Ring buffers outgrown mid-frame, tagged with the frame that last read
    /// them; dropped once the GPU completes it.
    private var retiredBuffers: [(frame: UInt64, buffer: MTLBuffer)] = []

    /// Instance storage for one pipeline kind, one buffer per slot. Draws
    /// append (instances plus uniforms) to the frame's slot. A buffer grows
    /// geometrically and is reused every frame after, never shrunk
    /// (`PERFORMANCE.md` §3): a growing screen reallocates a handful of
    /// times, not every frame.
    private final class InstanceBufferRing {
        private var buffers: [MTLBuffer?] = Array(repeating: nil, count: Metal4Backend.frameSlotCount)
        private var used = 0

        func beginFrame() {
            used = 0
        }

        /// Appends instances plus uniforms to `slot`, returning GPU addresses.
        /// Growth replaces the buffer rather than write memory an earlier
        /// draw of this frame still reads.
        func append(
            instances: UnsafeRawPointer, instanceByteCount: Int, uniforms: QuadUniforms,
            slot: Int, device: MTLDevice, residencySet: any MTLResidencySet,
            retire: (MTLBuffer) -> Void
        ) -> (instances: MTLGPUAddress, uniforms: MTLGPUAddress)? {
            let instanceOffset = Self.align(used)
            let uniformOffset = Self.align(instanceOffset + instanceByteCount)
            let needed = uniformOffset + MemoryLayout<QuadUniforms>.stride
            if buffers[slot] == nil || buffers[slot]!.length < needed {
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

    static func isSupported(by device: MTLDevice) -> Bool {
        device.supportsFamily(.metal4)
    }

    /// - Parameter slotWaitLimit: the longest `beginFrame` waits for a busy
    ///   slot before dropping the frame.
    public init(device: MTLDevice, slotWaitLimit: DispatchTimeInterval = Metal4Backend.defaultSlotWaitLimit)
        throws
    {
        guard Self.isSupported(by: device) else { throw Metal4BackendError.metal4Unsupported }
        self.device = device
        self.slotWaitLimit = slotWaitLimit
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
        // Created at zero and signalled once, not created at one: libdispatch
        // traps when a semaphore is freed below its initial value, which is
        // exactly the state `deinit` leaves every slot in.
        self.slotSemaphores = (0..<Self.frameSlotCount).map { _ in
            let semaphore = DispatchSemaphore(value: 0)
            semaphore.signal()
            return semaphore
        }

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

        // One compile per process, shared by every pane.
        let pipelines = try QuadPipelineCache.entry(for: device)
        self.solidPipeline = pipelines.solidPipeline
        self.glyphPipeline = pipelines.glyphPipeline
        self.colorGlyphPipeline = pipelines.colorGlyphPipeline
        self.sampler = pipelines.sampler
    }

    /// Releasing address-bound resources mid-execution is an `Invalid
    /// Resource` fault, so wait for every slot's last frame — bounded to a
    /// second in all, since a hung GPU must not hang teardown with it.
    deinit {
        let deadline = DispatchTime.now() + .seconds(1)
        for semaphore in slotSemaphores {
            _ = semaphore.wait(timeout: deadline)
        }
    }

    // MARK: - Frames

    /// Opens a frame into `target`, clearing it, so an empty frame still
    /// clears. `label` names the capture. A frame whose slot is still busy is
    /// dropped: nothing encodes, and `endFrame` presents without drawing.
    /// - Returns: whether the frame will be drawn; false for a dropped one.
    @discardableResult
    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String) -> Bool {
        // A frame left open is a bug in `TerminalRenderer.draw`; close it
        // rather than trap.
        if encoder != nil { endFrame(presenting: nil, onCompleted: nil) }
        dropRetired(through: completion.completed)

        let slot = nextSlot
        let wait: DispatchTime = consecutiveDroppedFrames > 0 ? .now() : .now() + slotWaitLimit
        guard slotSemaphores[slot].wait(timeout: wait) == .success else {
            consecutiveDroppedFrames += 1
            droppedFrameCount += 1
            if consecutiveDroppedFrames == Self.stalledQueueReportThreshold {
                Metal4Diagnostics.reportStalledQueue(droppedFrames: consecutiveDroppedFrames)
            }
            encoder = nil
            return false
        }
        consecutiveDroppedFrames = 0
        frameNumber += 1
        currentSlot = slot
        nextSlot = (slot + 1) % Self.frameSlotCount

        let allocator = allocators[slot]
        allocator.reset()
        let commandBuffer = commandBuffers[slot]
        commandBuffer.label = label
        commandBuffer.beginCommandBuffer(allocator: allocator)
        renderPassDescriptor.colorAttachments[0].texture = target
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            // Nothing will commit, so the slot is free again.
            commandBuffer.endCommandBuffer()
            slotSemaphores[slot].signal()
            completion.note(frameNumber)
            return false
        }
        encoder.label = label
        self.encoder = encoder
        lastScissor = nil
        lastViewport = nil
        lastPipeline = nil
        solidRing.beginFrame()
        glyphRing.beginFrame()
        colorGlyphRing.beginFrame()
        return true
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

    /// Untinted premultiplied sampling: colour glyphs and Kitty images.
    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize,
        transient: Bool = false
    ) {
        draw(
            instances, ring: colorGlyphRing, pipeline: colorGlyphPipeline, atlas: atlas,
            rect: rect, drawableSize: drawableSize, label: "Corta.colorGlyph", transientTexture: transient)
    }

    /// Commits and presents `drawable` (nil offscreen). `onCompleted` runs
    /// after the GPU finishes, with the commit's error — or at once with
    /// `.frameDropped` for a frame that was not drawn.
    func endFrame(
        presenting drawable: (any MTLDrawable)?, onCompleted: (@Sendable ((any Error)?) -> Void)?
    ) {
        guard let encoder else {
            // An unpresented drawable is never recycled (`FrameScheduler`),
            // so a dropped frame still presents; it shows the drawable's last
            // contents for one refresh.
            if let drawable {
                RenderMetrics.notePresent(of: drawable)
                drawable.present()
            }
            onCompleted?(Metal4BackendError.frameDropped)
            return
        }
        encoder.endEncoding()
        self.encoder = nil
        let commandBuffer = commandBuffers[currentSlot]
        commandBuffer.endCommandBuffer()

        // `MTL4CommandQueue`'s contract; a queue-side ordering, not a CPU block.
        if let drawable {
            queue.waitForDrawable(drawable)
        }
        let options = MTL4CommitOptions()
        let frame = frameNumber
        let completion = completion
        let slotReleased = slotSemaphores[currentSlot]
        options.addFeedbackHandler { feedback in
            if let error = feedback.error {
                Metal4Diagnostics.reportCommitFault(error)
            }
            completion.note(frame)
            slotReleased.signal()
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

    /// Test seam: the GPU runs no later commit until `event` reaches `value`
    /// — a stalled GPU on demand, for `Metal4BackendTests`.
    func holdQueue(until event: any MTLEvent, reaches value: UInt64) {
        queue.waitForEvent(event, value: value)
    }

    // MARK: - Encoding

    private func draw(
        _ instances: [QuadInstance],
        ring: InstanceBufferRing,
        pipeline: MTLRenderPipelineState,
        atlas: MTLTexture?,
        rect: CGRect,
        drawableSize: CGSize,
        label: String,
        transientTexture: Bool = false
    ) {
        // The pass (and its clear) opened in `beginFrame`.
        guard let encoder, !instances.isEmpty else { return }

        // The scissor keeps every instance inside `rect`.
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
                    slot: currentSlot, device: device, residencySet: residencySet
                ) { [self] buffer in
                    retiredBuffers.append((frame: frameNumber, buffer: buffer))
                }
            })
        else { return }
        argumentTable.setAddress(addresses.0, index: 0)
        argumentTable.setAddress(addresses.1, index: 1)
        if let atlas {
            makeResident(atlas, transient: transientTexture)
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
    private func makeResident(_ texture: MTLTexture, transient: Bool) {
        let id = ObjectIdentifier(texture)
        if boundTextures[id] == nil {
            residencySet.addAllocation(texture)
            residencySet.commit()
        }
        boundTextures[id] = (texture: texture, lastFrame: frameNumber,
            retentionFrames: transient ? 0 : Self.textureRetentionFrames)
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
            $0.value.lastFrame + $0.value.retentionFrames <= completed
        }
        for (id, entry) in expiredTextures {
            residencySet.removeAllocation(entry.texture)
            boundTextures.removeValue(forKey: id)
            removedAny = true
        }
        if removedAny { residencySet.commit() }
        retiredBuffers = keptBuffers
    }
}
